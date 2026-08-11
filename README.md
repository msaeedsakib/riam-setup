# RIAM

A voice-only, local-first AI life assistant for macOS. One continuous conversation, memory that does not degrade, and nothing but a menu-bar icon until you speak to it.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/msaeedsakib/riam-setup/main/install.sh | sh
```

That installs the `riam` binary to `~/.local/bin`, `RIAM.app` to `~/Applications`, registers the background service, and opens the app. Everything else — providers, model roles, voice, calendar — you set up inside the app.

Requires macOS 12 or newer on an Intel Mac. Apple Silicon builds are not published yet; the installer will tell you rather than install something that cannot run.

## What this repo is

The public install and update channel. Each release carries the Intel binary tarball and `RIAM.app` zip, a `manifest.json` the daemon polls for updates, and a `latest.txt` index of sha256 checksums that `install.sh` verifies before installing anything. The source lives elsewhere.

## Updating

RIAM updates itself: it polls this channel, verifies each artifact's checksum, waits until you are not mid-conversation, swaps the binary and app bundle, and restarts. To do it by hand:

```sh
riam update --check
riam update --now
riam update --rollback
```

## Uninstalling

```sh
riam daemon --uninstall-service
rm -rf ~/Applications/RIAM.app ~/.local/bin/riam
```

Your data stays in `~/.riam` until you remove it yourself. Take a backup first with `riam backup` if you might come back.
