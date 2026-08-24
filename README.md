# RIAM

A local-first AI life assistant that lives on your own Linux box. One continuous
conversation, memory that does not degrade, a PWA you install from your own domain —
chat, voice, and proactive nudges by web push.

## Install

On a linux-aarch64 server you control (nginx and systemd present, a domain's A record
pointed at it):

```sh
curl -fsSL https://raw.githubusercontent.com/msaeedsakib/riam-setup/main/install.sh | sudo sh
```

The installer asks for your domain, checks DNS points at the box, creates a `riam`
system user, installs the daemon, obtains a TLS certificate via acme.sh, writes a
self-contained nginx vhost, and prints a one-time claim URL. Open that URL on the
device that should hold the passkey; everything else — providers, model roles, voice —
is set up in the app it serves.

macOS is no longer a server target: 2.0.x Mac installs keep working but get no
updates.

## What this repo is

The public install and update channel. Each release carries the linux-aarch64 binary
tarball (the web app is embedded in it), a `manifest.json` the daemon polls for
updates, and a `latest.txt` index of sha256 checksums that `install.sh` verifies
before installing anything. The source lives elsewhere.

## Updating

RIAM updates itself: it polls this channel, verifies checksums, waits until you are
not mid-conversation, swaps the binary and exits; systemd restarts the new build. By
hand, on the server:

```sh
riam update --check
riam update --now
riam update --rollback
```

## Uninstalling

```sh
sudo systemctl disable --now riam
sudo rm /etc/systemd/system/riam.service /etc/nginx/conf.d/riam.conf /usr/local/bin/riam
sudo systemctl reload nginx
```

Your data stays in `/home/riam/.riam` until you remove the user. Take a backup first
with `riam backup` if you might come back.
