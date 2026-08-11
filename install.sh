#!/bin/sh
# RIAM installer: download the latest release from the public GitHub channel, install the riam binary and RIAM.app, then run `riam setup`.
# Usage: curl -fsSL https://raw.githubusercontent.com/msaeedsakib/riam-setup/main/install.sh | sh
#        (or: sh install.sh [--dry-run] [--local <path>] [--no-setup])
set -eu
# shellcheck disable=SC3040
if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi

BASE_URL="${RIAM_BASE_URL:-https://github.com/msaeedsakib/riam-setup/releases/latest/download}"
INSTALL_DIR="${RIAM_INSTALL_DIR:-$HOME/.local/bin}"
APPS_DIR="${RIAM_APPS_DIR:-$HOME/Applications}"
LABEL="dev.riam.daemon"

dry_run=0
local_src=""
run_setup=1

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
	printf 'install.sh: %s\n' "$*" >&2
	exit 1
}
act() {
	# In dry-run, print the intended action; otherwise run it.
	if [ "$dry_run" -eq 1 ]; then
		printf '  would: %s\n' "$*" >&2
	else
		"$@"
	fi
}

usage() {
	cat <<'EOF'
RIAM installer

  sh install.sh [options]

Options:
  --dry-run          print every action without doing any of it
  --local <path>     install from a local riam binary or .tar.gz (no download)
  --no-setup         install but do not launch `riam setup`
  -h, --help         show this help

Environment overrides:
  RIAM_BASE_URL      release asset base URL (default: the public GitHub channel)
  RIAM_INSTALL_DIR   binary install directory (default $HOME/.local/bin)
  RIAM_APPS_DIR      RIAM.app install directory (default $HOME/Applications)
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) dry_run=1 ;;
	--no-setup) run_setup=0 ;;
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

detect_target() {
	os="$(uname -s)"
	[ "$os" = "Darwin" ] || die "RIAM supports macOS only (detected: $os)"
	arch="${RIAM_FORCE_ARCH:-$(uname -m)}"
	case "$arch" in
	arm64 | aarch64) target="aarch64-apple-darwin" ;;
	x86_64 | amd64) target="x86_64-apple-darwin" ;;
	*) die "unsupported architecture: $arch" ;;
	esac
	say "Detected platform: macOS $arch -> $target"
}

check_base_url() {
	[ -n "$BASE_URL" ] || die "RIAM_BASE_URL is empty"
	case "$BASE_URL" in
	*://*@*) die "RIAM_BASE_URL must not embed credentials" ;;
	https://* | http://localhost | http://localhost/* | http://localhost:* | http://127.0.0.1 | http://127.0.0.1/* | http://127.0.0.1:* | file://*) ;;
	*) die "RIAM_BASE_URL must use https (http is allowed only for localhost)" ;;
	esac
}

fetch() {
	url="$1"
	out="$2"
	case "$url" in
	file://*) act cp "${url#file://}" "$out" ;;
	*) act curl -fsSL "$url" -o "$out" ;;
	esac
}

# Verify a file against a known sha256 value; mandatory — this pipeline auto-executes the bytes it fetches.
verify_sha() {
	file="$1"
	expected="$2"
	if [ "$dry_run" -eq 1 ]; then
		say "  would: verify sha256 of $file"
		return 0
	fi
	[ -n "$expected" ] || die "no checksum published for $file; refusing to install unverified bytes"
	actual="$(shasum -a 256 "$file" | awk '{print $1}')"
	[ "$expected" = "$actual" ] || die "checksum mismatch for $file (expected $expected, got $actual)"
	say "Checksum verified: $(basename "$file")"
}

# Move an executable into INSTALL_DIR atomically (temp file on the same fs, then mv).
install_binary() {
	src="$1"
	[ "$dry_run" -eq 1 ] || [ -f "$src" ] || die "binary not found: $src"
	act mkdir -p "$INSTALL_DIR"
	dest="$INSTALL_DIR/riam"
	tmp="$INSTALL_DIR/.riam.install.$$"
	act cp "$src" "$tmp"
	act chmod 0755 "$tmp"
	act mv -f "$tmp" "$dest"
	say "Installed riam -> $dest"
}

# Unzip RIAM.app (ditto preserves bundle structure) and swap it into APPS_DIR.
install_app() {
	zipfile="$1"
	workdir="$2"
	act mkdir -p "$APPS_DIR"
	act /usr/bin/ditto -x -k "$zipfile" "$workdir/app"
	if [ "$dry_run" -eq 0 ] && [ ! -d "$workdir/app/RIAM.app" ]; then
		die "the app archive contains no RIAM.app"
	fi
	act rm -rf "$APPS_DIR/RIAM.app"
	act mv "$workdir/app/RIAM.app" "$APPS_DIR/RIAM.app"
	say "Installed RIAM.app -> $APPS_DIR/RIAM.app"
}

# Extract the riam binary from a .tar.gz into a work dir and echo its path.
extract_tarball() {
	tarball="$1"
	workdir="$2"
	act tar -xzf "$tarball" -C "$workdir"
	if [ "$dry_run" -eq 1 ]; then
		printf '%s' "$workdir/riam"
		return 0
	fi
	found="$(find "$workdir" -type f -name riam -perm -u+x -print -quit 2>/dev/null)"
	[ -n "$found" ] || found="$(find "$workdir" -type f -name riam -print -quit 2>/dev/null)"
	[ -n "$found" ] || die "no 'riam' binary inside $tarball"
	printf '%s' "$found"
}

restart_daemon_if_running() {
	uid="$(id -u)"
	target_svc="gui/$uid/$LABEL"
	if [ "$dry_run" -eq 1 ]; then
		say "Would restart the daemon if loaded: launchctl kickstart -k $target_svc"
		return 0
	fi
	if launchctl print "$target_svc" >/dev/null 2>&1; then
		if launchctl kickstart -k "$target_svc" >/dev/null 2>&1; then
			say "Restarted running daemon ($LABEL)"
		else
			warn "Note: could not restart the daemon; run 'riam daemon --service-status'"
		fi
	else
		say "Daemon not loaded; nothing to restart"
	fi
}

install_from_local() {
	src="$1"
	say "Local install source: $src"
	case "$src" in
	*.tar.gz | *.tgz)
		work="$(mktemp -d)"
		trap 'rm -rf "$work"' EXIT
		if [ -f "$src.sha256" ]; then
			expected="$(awk '{print $1; exit}' "$src.sha256")"
			verify_sha "$src" "$expected"
		else
			say "No $src.sha256 beside the archive; verification skipped (explicit --local developer path)"
		fi
		bin="$(extract_tarball "$src" "$work")"
		install_binary "$bin"
		;;
	*)
		say "Local source is a bare binary; verification skipped (no archive or checksum provided)"
		install_binary "$src"
		;;
	esac
}

# The flat release index published beside manifest.json: `version X.Y.Z`, then `<key> <file> <sha256>` lines.
read_release_index() {
	work="$1"
	fetch "$BASE_URL/latest.txt" "$work/latest.txt"
	if [ "$dry_run" -eq 1 ]; then
		VERSION="0.0.0-dry-run"
		bin_file="riam-dry-run.tar.gz"
		bin_sha=""
		app_file=""
		app_sha=""
		return 0
	fi
	VERSION="$(awk '$1 == "version" {print $2; exit}' "$work/latest.txt")"
	[ -n "$VERSION" ] || die "the release index has no version line"
	bin_file="$(awk -v t="$target" '$1 == t {print $2; exit}' "$work/latest.txt")"
	bin_sha="$(awk -v t="$target" '$1 == t {print $3; exit}' "$work/latest.txt")"
	[ -n "$bin_file" ] || die "the release has no artifact for $target"
	app_file="$(awk -v t="$target-app" '$1 == t {print $2; exit}' "$work/latest.txt")"
	app_sha="$(awk -v t="$target-app" '$1 == t {print $3; exit}' "$work/latest.txt")"
	say "Latest release: $VERSION"
}

install_from_remote() {
	detect_target
	check_base_url
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	read_release_index "$work"

	tarball="$work/$bin_file"
	fetch "$BASE_URL/$bin_file" "$tarball"
	verify_sha "$tarball" "$bin_sha"
	bin="$(extract_tarball "$tarball" "$work")"
	install_binary "$bin"

	if [ -n "$app_file" ]; then
		zipfile="$work/$app_file"
		fetch "$BASE_URL/$app_file" "$zipfile"
		verify_sha "$zipfile" "$app_sha"
		install_app "$zipfile" "$work"
	else
		say "This release carries no RIAM.app for $target; skipping the app"
	fi
}

# Point the daemon's self-updater at this channel (with a trailing slash, as it expects a base).
handoff_channel() {
	case "$BASE_URL" in
	file://*) return 0 ;;
	esac
	channel="$BASE_URL"
	case "$channel" in
	*/) : ;;
	*) channel="$channel/" ;;
	esac
	if [ "$dry_run" -eq 1 ]; then
		say "Would configure the update channel via: riam update --set-channel $channel"
		return 0
	fi
	if "$INSTALL_DIR/riam" update --set-channel "$channel" >/dev/null 2>&1; then
		say "Update channel configured"
	else
		warn "Note: could not configure the update channel; run 'riam update --set-channel <url>'"
	fi
}

main() {
	if [ "$dry_run" -eq 1 ]; then say "=== DRY RUN (no changes will be made) ==="; fi

	if [ -n "$local_src" ]; then
		install_from_local "$local_src"
	else
		install_from_remote
	fi

	case ":$PATH:" in
	*":$INSTALL_DIR:"*) : ;;
	*) say "Note: $INSTALL_DIR is not on your PATH. Add: export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
	esac

	handoff_channel
	restart_daemon_if_running

	if [ "$run_setup" -eq 0 ]; then
		say "Skipping 'riam setup' (--no-setup)"
		return 0
	fi
	if [ "$dry_run" -eq 1 ]; then
		say "Would exec: riam setup"
		return 0
	fi
	say "Launching 'riam setup'..."
	exec "$INSTALL_DIR/riam" setup
}

main
