#!/bin/sh
# RIAM installer: raise the riam daemon on a linux-aarch64 box behind nginx, then print the claim URL.
# Usage: curl -fsSL https://raw.githubusercontent.com/msaeedsakib/riam-setup/main/install.sh | sudo sh
#        (or: sudo sh install.sh [--dry-run] [--local <path>] [--no-certs])
set -eu
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

BASE_URL="${RIAM_BASE_URL:-https://github.com/msaeedsakib/riam-setup/releases/latest/download}"
RIAM_HOME="/home/riam"
BIN_DIR="$RIAM_HOME/bin"
DATA_DIR="$RIAM_HOME/.riam"
WEBROOT="/var/www/riam-acme"
CERT_DIR="/etc/nginx/riam-certs"
NGINX_CONF="/etc/nginx/conf.d/riam.conf"
UNIT="/etc/systemd/system/riam.service"

dry_run=0
local_src=""
do_certs=1
domain="${RIAM_DOMAIN:-}"
acme_email="${RIAM_ACME_EMAIL:-}"

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
	printf 'install.sh: %s\n' "$*" >&2
	exit 1
}
act() {
	if [ "$dry_run" -eq 1 ]; then
		printf '  would: %s\n' "$*" >&2
	else
		"$@"
	fi
}
as_riam() {
	act runuser -u riam -- env HOME="$RIAM_HOME" "$@"
}

usage() {
	cat <<'EOF'
RIAM installer (linux-aarch64, run as root)

  sudo sh install.sh [options]

Options:
  --dry-run          print every action without doing any of it
  --local <path>     install from a local riam binary or .tar.gz (no download)
  --no-certs         skip cert issuance (reuse existing certs in /etc/nginx/riam-certs)
  -h, --help         show this help

Environment:
  RIAM_BASE_URL      release asset base URL (default: the public GitHub channel)
  RIAM_DOMAIN        the domain to serve (skips the prompt)
  RIAM_ACME_EMAIL    account email for Let's Encrypt (skips the prompt)
  RIAM_SKIP_DNS=1    skip the DNS-points-here preflight
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) dry_run=1 ;;
	--no-certs) do_certs=0 ;;
	--local)
		shift
		[ $# -gt 0 ] || die "--local requires a path"
		local_src="$1"
		;;
	--local=*) local_src="${1#--local=}" ;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
	shift
done

# --- platform ---------------------------------------------------------------

os="${RIAM_FORCE_OS:-$(uname -s)}"
case "$os" in
Linux) ;;
Darwin) die "RIAM 2.1.0 moved to Linux — your existing Mac install keeps working but gets no updates" ;;
*) die "unsupported OS: $os" ;;
esac
arch="${RIAM_FORCE_ARCH:-$(uname -m)}"
case "$arch" in
aarch64 | arm64) target="aarch64-unknown-linux-gnu" ;;
*) die "RIAM ships for aarch64 linux only (detected: $arch)" ;;
esac

preflight() {
	missing=""
	[ "$(id -u)" -eq 0 ] || missing="$missing root(sudo)"
	for tool in nginx systemctl curl tar runuser useradd; do
		command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
	done
	if [ -n "$missing" ]; then
		if [ "$dry_run" -eq 1 ]; then
			warn "dry run: missing prerequisites:$missing"
		else
			die "missing prerequisites:$missing"
		fi
	fi
}

check_base_url() {
	[ -n "$BASE_URL" ] || die "RIAM_BASE_URL is empty"
	case "$BASE_URL" in
	*://*@*) die "RIAM_BASE_URL must not embed credentials" ;;
	https://* | http://localhost | http://localhost/* | http://localhost:* | http://127.0.0.1 | http://127.0.0.1/* | http://127.0.0.1:* | file://*) ;;
	*) die "RIAM_BASE_URL must use https (http is allowed only for localhost)" ;;
	esac
}

# --- domain -----------------------------------------------------------------

ask_domain() {
	if [ -z "$domain" ]; then
		[ "$dry_run" -eq 1 ] && die "dry run needs RIAM_DOMAIN set (no prompt)"
		printf 'Domain RIAM will be served at (e.g. riam.example.com): '
		read -r domain
	fi
	printf '%s' "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' ||
		die "that does not look like a domain: $domain"
}

check_vhost_conflict() {
	if nginx -T 2>/dev/null | grep -E '^\s*server_name\b' | grep -qw "$domain"; then
		die "nginx already serves $domain — pick another domain or remove that vhost"
	fi
}

check_dns() {
	[ "${RIAM_SKIP_DNS:-0}" = 1 ] && return 0
	public_ip="$(curl -fsS -4 --max-time 10 https://checkip.amazonaws.com 2>/dev/null ||
		curl -fsS -4 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
	[ -n "$public_ip" ] || die "could not learn this box's public IP (set RIAM_SKIP_DNS=1 to override)"
	resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')"
	[ -n "$resolved" ] || die "$domain does not resolve — create an A record to $public_ip first"
	[ "$resolved" = "$public_ip" ] ||
		die "$domain resolves to $resolved but this box is $public_ip — fix DNS first (cert issuance would fail)"
	say "DNS ok: $domain -> $public_ip"
}

# --- user, dirs, nginx seam -------------------------------------------------

ensure_user() {
	if ! id riam >/dev/null 2>&1; then
		shell="$(command -v nologin || echo /usr/sbin/nologin)"
		act useradd --system --create-home --home-dir "$RIAM_HOME" --shell "$shell" riam
	fi
	act install -d -o riam -g riam -m 755 "$BIN_DIR"
	act install -d -o riam -g riam -m 750 "$DATA_DIR"
	act chmod 750 "$RIAM_HOME"
}

grant_nginx() {
	nginx_user="$(nginx -T 2>/dev/null | awk '$1 == "user" {gsub(";", "", $2); print $2; exit}' || true)"
	if [ -z "$nginx_user" ]; then
		if id -u www-data >/dev/null 2>&1; then nginx_user="www-data"; else nginx_user="nginx"; fi
	fi
	if ! id -u "$nginx_user" >/dev/null 2>&1; then
		[ "$dry_run" -eq 1 ] || die "cannot find nginx's user ($nginx_user)"
	fi
	act usermod -aG riam "$nginx_user"
	say "nginx user $nginx_user joined the riam group (socket access)"
}

# --- binary -----------------------------------------------------------------

fetch() {
	url="$1"
	out="$2"
	case "$url" in
	file://*) act cp "${url#file://}" "$out" ;;
	*) act curl -fsSL "$url" -o "$out" ;;
	esac
}

verify_sha() {
	file="$1"
	expected="$2"
	if [ "$dry_run" -eq 1 ]; then
		say "  would: verify sha256 of $file"
		return 0
	fi
	[ -n "$expected" ] || die "no checksum published for $file; refusing to install unverified bytes"
	actual="$(sha256sum "$file" | awk '{print $1}')"
	[ "$expected" = "$actual" ] || die "checksum mismatch for $file (expected $expected, got $actual)"
	say "Checksum verified: $(basename "$file")"
}

extract_tarball() {
	tarball="$1"
	workdir="$2"
	act tar -xzf "$tarball" -C "$workdir"
	if [ "$dry_run" -eq 1 ]; then
		printf '%s' "$workdir/riam"
		return 0
	fi
	found="$(find "$workdir" -type f -name riam -print -quit 2>/dev/null)"
	[ -n "$found" ] || die "no 'riam' binary inside $tarball"
	printf '%s' "$found"
}

install_binary() {
	src="$1"
	[ "$dry_run" -eq 1 ] || [ -f "$src" ] || die "binary not found: $src"
	tmp="$BIN_DIR/.riam.install.$$"
	act cp "$src" "$tmp"
	act chown riam:riam "$tmp"
	act chmod 0755 "$tmp"
	act mv -f "$tmp" "$BIN_DIR/riam"
	act ln -sf "$BIN_DIR/riam" /usr/local/bin/riam
	say "Installed riam -> $BIN_DIR/riam (symlink /usr/local/bin/riam)"
}

read_release_index() {
	work="$1"
	fetch "$BASE_URL/latest.txt" "$work/latest.txt"
	if [ "$dry_run" -eq 1 ]; then
		VERSION="0.0.0-dry-run"
		bin_file="riam-dry-run.tar.gz"
		bin_sha=""
		return 0
	fi
	VERSION="$(awk '$1 == "version" {print $2; exit}' "$work/latest.txt")"
	[ -n "$VERSION" ] || die "the release index has no version line"
	bin_file="$(awk -v t="$target" '$1 == t {print $2; exit}' "$work/latest.txt")"
	bin_sha="$(awk -v t="$target" '$1 == t {print $3; exit}' "$work/latest.txt")"
	[ -n "$bin_file" ] || die "the release has no artifact for $target"
	say "Latest release: $VERSION"
}

obtain_binary() {
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	if [ -n "$local_src" ]; then
		case "$local_src" in
		*.tar.gz | *.tgz)
			if [ -f "$local_src.sha256" ]; then
				verify_sha "$local_src" "$(awk '{print $1; exit}' "$local_src.sha256")"
			else
				say "No $local_src.sha256 beside the archive; verification skipped (explicit --local)"
			fi
			bin="$(extract_tarball "$local_src" "$work")"
			;;
		*)
			say "Local source is a bare binary; verification skipped (explicit --local)"
			bin="$local_src"
			;;
		esac
	else
		check_base_url
		read_release_index "$work"
		tarball="$work/$bin_file"
		fetch "$BASE_URL/$bin_file" "$tarball"
		verify_sha "$tarball" "$bin_sha"
		bin="$(extract_tarball "$tarball" "$work")"
	fi
	install_binary "$bin"
}

# --- config, systemd --------------------------------------------------------

write_config() {
	cfg="$DATA_DIR/config.toml"
	if [ "$dry_run" -eq 1 ]; then
		say "  would: ensure [server] domain = \"$domain\" in $cfg"
		return 0
	fi
	if [ ! -f "$cfg" ]; then
		printf '[server]\ndomain = "%s"\n' "$domain" >"$cfg"
		chown riam:riam "$cfg"
		chmod 600 "$cfg"
	elif ! grep -q '^\[server\]' "$cfg"; then
		printf '\n[server]\ndomain = "%s"\n' "$domain" >>"$cfg"
	else
		warn "Note: $cfg already has a [server] section; make sure domain = \"$domain\""
	fi
}

write_unit() {
	if [ "$dry_run" -eq 1 ]; then
		say "  would: write $UNIT and enable riam.service"
		return 0
	fi
	cat >"$UNIT" <<EOF
[Unit]
Description=RIAM daemon
After=network-online.target
Wants=network-online.target

[Service]
User=riam
Group=riam
Environment=HOME=$RIAM_HOME
ExecStart=$BIN_DIR/riam daemon
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now riam
}

wait_for_socket() {
	[ "$dry_run" -eq 1 ] && return 0
	i=0
	while [ $i -lt 30 ]; do
		[ -S "$DATA_DIR/riam.sock" ] && return 0
		i=$((i + 1))
		sleep 1
	done
	die "the daemon did not open $DATA_DIR/riam.sock in 30s — check: journalctl -u riam"
}

# --- nginx + certs ----------------------------------------------------------

write_nginx_http_only() {
	[ "$dry_run" -eq 1 ] && {
		say "  would: write $NGINX_CONF (http-only) and reload nginx"
		return 0
	}
	install -d -m 755 "$WEBROOT"
	cat >"$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
	nginx -t
	systemctl reload nginx
}

issue_certs() {
	[ "$dry_run" -eq 1 ] && {
		say "  would: issue an ECC cert for $domain via acme.sh (webroot $WEBROOT)"
		return 0
	}
	if [ "$do_certs" -eq 0 ]; then
		[ -f "$CERT_DIR/fullchain.pem" ] || die "--no-certs but $CERT_DIR/fullchain.pem does not exist"
		return 0
	fi
	ACME="$HOME/.acme.sh/acme.sh"
	if [ ! -x "$ACME" ]; then
		if [ -z "$acme_email" ]; then
			printf 'Email for the Let'\''s Encrypt account (expiry notices): '
			read -r acme_email
		fi
		curl -fsSL https://get.acme.sh | sh -s "email=$acme_email"
	fi
	"$ACME" --set-default-ca --server letsencrypt
	"$ACME" --issue -d "$domain" -w "$WEBROOT" --keylength ec-256
	install -d -m 700 "$CERT_DIR"
	"$ACME" --install-cert -d "$domain" --ecc \
		--fullchain-file "$CERT_DIR/fullchain.pem" \
		--key-file "$CERT_DIR/key.pem" \
		--reloadcmd "systemctl reload nginx"
}

write_nginx_full() {
	[ "$dry_run" -eq 1 ] && {
		say "  would: write $NGINX_CONF (tls proxy) and reload nginx"
		return 0
	}
	cat >"$NGINX_CONF" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    "" close;
}
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;
    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;
    client_max_body_size 25m;
    location / {
        proxy_pass http://unix:$DATA_DIR/riam.sock;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
	nginx -t
	systemctl reload nginx
}

verify_health() {
	[ "$dry_run" -eq 1 ] && return 0
	i=0
	while [ $i -lt 10 ]; do
		if curl -fsS --max-time 5 "https://$domain/api/health" >/dev/null 2>&1; then
			say "Health check ok: https://$domain/api/health"
			return 0
		fi
		i=$((i + 1))
		sleep 2
	done
	die "https://$domain/api/health does not answer — check: journalctl -u riam, nginx -t"
}

handoff_channel() {
	case "$BASE_URL" in file://*) return 0 ;; esac
	channel="$BASE_URL"
	case "$channel" in */) : ;; *) channel="$channel/" ;; esac
	if [ "$dry_run" -eq 1 ]; then
		say "  would: set the update channel to $channel"
		return 0
	fi
	if ! as_riam "$BIN_DIR/riam" update --set-channel "$channel" >/dev/null 2>&1; then
		warn "Note: could not configure the update channel; run as riam: riam update --set-channel $channel"
	fi
}

print_claim() {
	if [ "$dry_run" -eq 1 ]; then
		say "Would print the claim URL from: riam auth claim"
		return 0
	fi
	url="$(runuser -u riam -- env HOME="$RIAM_HOME" "$BIN_DIR/riam" auth claim)" ||
		die "could not mint a claim URL — check: journalctl -u riam"
	say ""
	say "RIAM is up. Open this on the device that will hold the passkey (expires in 30 minutes):"
	say ""
	say "  $url"
}

main() {
	[ "$dry_run" -eq 1 ] && say "=== DRY RUN (no changes will be made) ==="
	preflight
	ask_domain
	[ "$dry_run" -eq 1 ] || check_vhost_conflict
	check_dns
	ensure_user
	grant_nginx
	obtain_binary
	write_config
	write_unit
	wait_for_socket
	write_nginx_http_only
	issue_certs
	write_nginx_full
	verify_health
	handoff_channel
	print_claim
}

main
