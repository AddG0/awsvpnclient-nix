# AWS VPN Client for NixOS - Development Notes

This document captures the debugging process and key learnings for packaging the AWS VPN Client on NixOS.

## Architecture Overview

The package is split into:
- `pkgs/shared.nix` - deb extraction (used by both GUI and daemon)
- `pkgs/application.nix` - Electron GUI wrapped in buildFHSEnv
- `pkgs/service.nix` - privileged daemon wrapped in buildFHSEnv
- `pkgs/caller-path-hook.c` - small LD_PRELOAD shim so the daemon's caller check
  accepts the sandboxed GUI/CLI (see "Caller path validation" below)
- `module.nix` - NixOS module (systemd unit + state/runtime directories)

## What 6.0.0 changed

6.0.0 ("Zentry") is a ground-up rewrite and invalidates almost everything the 5.x
packaging had to work around:

| 5.x | 6.x |
|-----|-----|
| .NET/GTK GUI (`ACVC.GTK`) | Electron 40 GUI |
| .NET service (`ACVC.GTK.Service`) | single Rust binary `aws-client-vpn-daemon` |
| D-Bus IPC (private `dbus-daemon`) | gRPC over a Unix socket |
| bundled musl `acvc-openvpn` + `openssl` subprocesses | OpenVPN 3 and aws-lc linked in-process |
| SHA256 checksum validation of openvpn resources | none |
| FIPS provider had to be activated via `fipsinstall` | no activation step; `UnableToEnforceFipsException` is gone |
| SQLite native lib segfaulted, stripped from `.deps.json` | SQLite works; no manifest edits |
| no CLI | `aws-vpn-client` CLI, exposed as `.#awsvpnclient-cli` |
| GTK front-end followed the system theme | Electron paints its own light-only palette |

So the musl/LD_PRELOAD hazards, the `.deps.json` `jq` rewrite, the `fipsmodule.cnf`
generation, the `env` PATH wrapper, and the D-Bus boolean shim are all gone. What
remains is the caller-path hook, the two dropdown-popup patches, and - only if you
want the GUI themed - the palette rewrite described below.

Runtime layout:
- IPC socket: `/run/awsvpnclient/com.aws.vpn-client.daemon.sock` (mode 0666, so the
  unprivileged GUI can connect)
- state: `/var/lib/awsvpnclient` (**must be 0700**)
- logs: `/var/log/awsvpnclient/aws_vpn_client_{daemon,cli,gui}_<date>.log`

On first run the daemon migrates 5.x profiles and preferences into its own store.

## Updating the version

For a routine bump, edit `versionInfo` in `pkgs/shared.nix` (`version` + `sha256`)
with the values from the [AWS Linux release notes](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-release-notes.html),
then `nix build .#awsvpnclient-service .#default`. Test an actual connection
afterwards - AWS adds new runtime checks between releases.

Get the hash with:

```bash
nix store prefetch-file --hash-type sha256 --json \
  "https://d20adtppz83p9s.cloudfront.net/GTK/<version>/awsvpnclient_amd64.deb"
nix hash convert --hash-algo sha256 --to base16 "sha256-..."
```

## Key Challenges & Solutions

### 1. Why buildFHSEnv for the GUI and daemon

Both resolve paths under a hardcoded `/opt/awsvpnclient` prefix - the daemon reads
`app_version` and runs `dns/configure-dns`; `configure-dns` in turn calls
`/usr/bin/{mkdir,rm,date,resolvectl}` by absolute path. The daemon's RPATH also starts
with `$ORIGIN`, which is how it finds the aws-lc `libssl.so`/`libcrypto.so` it ships
beside itself, and `patchelf --shrink-rpath` would drop that entry. So `mkDeb` sets
`dontPatchELF`/`dontStrip`/`dontPatchShebangs`, and those two run under `buildFHSEnv`,
which supplies libraries at standard paths without touching the binaries.

The CLI is the exception: it resolves nothing under the prefix and links only
libc/libm/libgcc_s, so it uses `autoPatchelfHook` and skips the sandbox entirely.

### 2. Only `opt/` may be installed from the .deb

A top-level directory present in the FHS rootfs is `--ro-bind`ed over the host's and
excluded from bubblewrap's automatic host bind-mounts. The .deb ships an empty
`var/lib/awsvpnclient`, so installing `var/` would leave the daemon with an empty,
unwritable `/var/lib` and `/var/log` inside the sandbox. (`/etc` is the exception -
buildFHSEnv binds its children individually and always exposes the host's as
`/.host-etc` - but the .deb's `etc/systemd` and `usr/` are unused anyway: the unit
comes from `module.nix` and the desktop entry from `application.nix`.)
`installPhase` copies `opt/` only.

### 3. Three trees, one download

`mkDeb` extracts the .deb and nothing else; the daemon and CLI use it as-is.
`mkGuiFiles` builds the GUI's tree on top: it symlinks 26 of the 27 entries straight
back to `mkDeb`'s output and materialises only `resources/`, with `app.asar` rebuilt.

The one entry it cannot symlink is the Electron executable. `/proc/self/exe` resolves
symlinks, and Electron looks for `resources/` next to the *resolved* path - so a
symlinked binary silently loads the original, unpatched asar. That 205 MB copy is the
price of patching anything in the asar at all.

### 4. Executable bits

The .deb ships `aws-client-vpn-daemon`, `aws-vpn-client` and `dns/configure-dns`
non-executable and relies on its `postinst` to `chmod` them. `shared.nix` does that
at build time.

### 5. Caller path validation

Every IPC request is guarded by the daemon's process validator: it `readlink()`s
`/proc/<caller>/exe` and rejects the call unless the executable sits directly in
`/opt/awsvpnclient`. Because the GUI runs in its own bubblewrap sandbox where
`/opt/awsvpnclient` is a bind mount of a Nix store path, the daemon (in a different
mount namespace) sees:

```
Binary path of caller PID: 418916 is
/nix/store/...-awsvpnclient-deb-6.0.1/opt/awsvpnclient/AWS VPN Client, not allowed
```

`caller-path-hook.c` is LD_PRELOADed into the daemon and rewrites a `/proc/<pid>/exe`
target ending in `/opt/awsvpnclient/AWS VPN Client` or `/opt/awsvpnclient/aws-vpn-client`
back to that bare path. Everything else is returned untouched.

The validator only accepts those two names, so **neither binary may be renamed**
(5.x packaging renamed `AWS VPN Client` to `awsvpnclient`; doing that now breaks IPC).

FORTIFY_SOURCE is disabled when building the hook because it defines libc symbols
that glibc's fortified headers redirect to `__*_chk` variants.

### 6. State directory permissions

The daemon validates `/var/lib/awsvpnclient` and refuses it unless the mode is
exactly 0700:

```
Existing directory has insecure permissions path=/var/lib/awsvpnclient
  error=Directory has insecure permissions: 755, expected 700
Metrics initialization failed, continuing without metrics
```

This is non-fatal (only metrics are lost), but the module sets
`StateDirectory=awsvpnclient` with `StateDirectoryMode=0700`. A 5.x install leaves a
0755 directory behind, which is where this bites on upgrade.

### 7. Theming the GUI

Upstream's UI is light-only and has no theme support whatsoever: no
`prefers-color-scheme`, no `nativeTheme`, no theme preference, and a 549-byte
stylesheet. Electron 40 is also built without Blink's auto-dark feature - the binary
has no `WebContentsForceDark` string - so `--force-dark-mode` only flips
`nativeTheme`, which `main.js` never reads. Stylix cannot reach any of it, because
the app paints its own colours rather than using a toolkit.

What it does have is a contiguous block of hex design tokens in the minified
renderer bundle:

```js
We="#FCFCFD",cu="#EBEBF0",qe="#FFFFFF",...,Ee="#FF9900",ha="#F0F0F0",_u="#DEDEE3"
```

`designTokens` in `shared.nix` maps each to a base16 slot, and `mkGuiFiles` rewrites
them when a palette is supplied. `programs.awsvpnclient.palette` defaults to
`config.lib.stylix.colors`; `null` leaves the colours alone.

Three things the token rewrite cannot express, all handled alongside it:

1. **On-accent text.** Upstream writes every primary button as
   `background: Ee, color: F`, so `#0F141A` is *both* body text and the text drawn on
   the accent - 9 of its 38 uses are on-accent. Both want dark in the stock light
   theme; in a dark scheme body text must go light while on-accent text must stay
   dark, and one literal cannot become two colours. The accent buttons are caught by
   an attribute selector on their serialised inline background, appended to the
   bundle's stylesheet (`style-src 'self'` permits a same-origin sheet; an inline
   `<style>` would be blocked).
2. **UA surfaces.** Chromium paints form-control popups, scrollbars and similar from
   `color-scheme`, which the page never declares - hence a light dropdown over a dark
   UI. The same appended stylesheet sets `:root{color-scheme:dark}`.
3. **The native menubar.** Electron's default application menu is a GTK widget, so no
   page CSS reaches it, and the host's GTK settings and theme packages are not on
   `XDG_DATA_DIRS` inside the FHS env. `application.nix` derives polarity from
   base00's perceived luminance and exports `GTK_THEME=Adwaita:dark` for dark
   palettes. This is Adwaita, not the base16 palette; theming it properly would mean
   getting a real GTK theme package and the user's `settings.ini` into the sandbox.

`app.asar` records a SHA256 per file in its header, so it is extracted and repacked
rather than byte-patched (a length-preserving patch would leave the hashes stale -
unenforced on Linux today, since Electron's ASAR integrity fuse is macOS/Windows
only, but not worth relying on). `asar pack --unpack '*.node'` keeps
`daemon-client.node` outside the archive where Electron can `dlopen` it; the build
asserts it survives.

**The package argument is `base16Palette`, not `palette`**: nixpkgs has a package
called `palette`, so `callPackage` would inject it and shadow the `null` default,
failing with `attribute 'base0D' missing`.

Every mapped literal is asserted present before rewriting, so a release that
reshuffles the palette fails the build instead of theming the app halfway.

### 8. Dropdown popup patches

Two upstream bugs in the Electron dropdown popup, both patched in `mkGuiFiles`
whether or not a palette is set. Both use `substituteInPlace --replace-fail`, which
doubles as the assertion.

**Oversized window.** The popup is sized by formula, not content:

```js
const o = Math.min(e.length * 36 + 20, 204),   // height
      c = t === ae ? n.width + 4 : 300;         // width - hardcoded for the actions menu
g = new I({ width:c, height:o, frame:!1, transparent:!0, ... });
```

Items render 32px tall, not 36, and the actions menu ignores its content width, so a
4-item menu is a 300x164 window around 141x134 of painted content. Because the window
is `transparent: true` the app never notices, but the compositor borders, rounds and
hit-tests the full rect - and with no `color-scheme` declared, Chromium used to paint
that dead area white, which is the light box that appeared around the menu. The patch
measures `#root`'s first child after `ready-to-show` and `setBounds` to it. Width is
only fitted for the actions menu; the profile dropdown's width deliberately tracks its
select box, so that one keeps upstream's value (verified: select 299 wide -> popup 303,
height 92 -> 68).

**Popup never closes.** The only automatic close path is `g.on("blur")`, and the main
window has no handler that dismisses it. These transparent frameless XWayland windows
do not reliably take focus under wlroots compositors, so blur never fires, the popup
lingers, and `alwaysOnTop` is not honoured either - it ends up behind the main window.
The patch adds `w.focus()` after `w.show()` so blur can fire at all, plus an
`i.on("focus")` on the main window that closes the popup the same way blur does. The
second path does not depend on the popup ever having been focused.

**Both patches are textual, so the build runs `node --check` on the result.** An
injection that produces invalid JS fails the build; without it a bad edit packs
cleanly and the app simply refuses to start.

### 9. DNS

`dns/configure-dns` calls `/usr/bin/{mkdir,rm,date}` and `/usr/bin/resolvectl` by
absolute path, so `coreutils` and `systemd` are in the daemon's `targetPkgs`;
`resolvectl` reaches the host's `systemd-resolved` over the system bus under the
bound-in `/run`. The module enables `services.resolved`.

The 5.x `#!/usr/bin/env bash` PATH problem does not recur: it was caused by the musl
openvpn subprocess, and openvpn is now in-process.

## Testing Techniques

### Running the daemon by hand

`buildFHSEnv` passes `--die-with-parent` to bubblewrap, so backgrounding the wrapper
from a shell that then exits kills the daemon and leaves a stale socket behind. Use
systemd instead:

```bash
svc=$(nix build .#awsvpnclient-service --no-link --print-out-paths)
sudo systemd-run --unit=awsvpn-test --collect "$svc/bin/awsvpnclient-service"
journalctl -u awsvpn-test -f
sudo systemctl stop awsvpn-test
```

### Testing Inside the FHS Environment

Create a test script and inject it into the FHS wrapper:

```bash
cat > /tmp/my-test.sh << 'EOF'
#!/bin/bash
source /etc/profile
# Your test commands here
EOF
chmod +x /tmp/my-test.sh

servicePath=$(nix build .#awsvpnclient-service --no-link --print-out-paths)
sed 's|/nix/store/[a-z0-9]*-awsvpnclient-service-init|/tmp/my-test.sh|' \
  "$servicePath/bin/awsvpnclient-service" > /tmp/test-wrapper.sh
chmod +x /tmp/test-wrapper.sh
sudo /tmp/test-wrapper.sh
```

### The CLI as a probe

The .deb ships an `aws-vpn-client` CLI that exercises the same IPC surface as the
GUI without needing a display:

```
list-profiles  list-connections  list-preferences  get-connection-status
connect  disconnect  import-profile  send-diagnostic-logs
```

It is exposed as `.#awsvpnclient-cli` and the module installs it alongside the GUI.
It is the one component with no FHS environment - it resolves nothing under the
install prefix and needs only libc/libm/libgcc_s, so `autoPatchelfHook` suffices,
which is why its closure is 46 MB against the GUI's 2 GB. `$out/bin/aws-vpn-client`
symlinks into `$out/opt/awsvpnclient/`, because the daemon validates callers by the
tail of their `/proc/<pid>/exe`.

### Viewing logs

```bash
sudo tail -f /var/log/awsvpnclient/aws_vpn_client_daemon_*.log
sudo cat /var/log/awsvpnclient/configure-dns-up.log
sudo cat /var/log/awsvpnclient/configure-dns-down.log
```

`dns/configure-dns` documents and reads `ZENTRY_LOG_DIR` to relocate its logs. The
daemon carries `ZENTRY_LOG` (log level) and what looks like the same `ZENTRY_LOG_DIR`
in its string table, but neither has been tested here.

### Inspecting a new release

The daemon is an unstripped Rust binary, so its behaviour is largely readable from
`strings`: module paths (`src/daemon/src/...`), log messages, env var names and
hardcoded paths all survive. That is how the caller check and the 0700 requirement
above were found.

## Required System Utilities

The daemon expects these at standard FHS paths:
- `resolvectl` - /usr/bin/resolvectl (DNS configuration, from systemd)
- `mkdir`, `rm`, `date` - /usr/bin/... (used by `dns/configure-dns`)
- `ip` - /sbin/ip (from iproute2, routing table operations)

## Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Binary path of caller PID ... not allowed` | Caller check vs sandbox | `caller-path-hook.c` rewrites `/proc/*/exe` readlink |
| `Connection failed: transport error` (GUI) | Daemon not running, or stale socket after it died | Check the unit; `RuntimeDirectory` clears the socket |
| `Directory has insecure permissions: 755, expected 700` | `/var/lib/awsvpnclient` left from a 5.x install | `StateDirectoryMode=0700` |
| `libgbm.so.1: cannot open shared object file` | Electron dep missing from `targetPkgs` | Add the library (`libgbm`) |
| `design token #XXXXXX is no longer in the renderer bundle` | Release reshuffled the GUI palette | Re-audit `designTokens` in `shared.nix` |
| `attribute 'base0D' missing` when building the GUI | Argument named `palette` collides with `pkgs.palette` | Keep it named `base16Palette` |
| GUI dies the moment the launching shell exits | `buildFHSEnv` sets bwrap `--die-with-parent` | Launch via systemd, not a backgrounded shell |
| `substituteInPlace: pattern not found` | Release rewrote a patched `main.js` handler | Re-audit the popup patches in `shared.nix` |
| GUI exits immediately, no window | Injected JS is malformed | The `node --check` gate should catch this at build time |
| `Could not start dynamically linked executable` | Running a binary outside the FHS env | Use the wrapper, not the raw store path |
| `Failed to obtain Cognito identity` | Telemetry upload without credentials | Benign |

## Version Override

The package supports overriding the version:

```nix
awsvpnclient.overrideVersion {
  version = "6.0.1";
  sha256 = "...";
}
```

## Running

```bash
# Terminal 1: Start daemon (requires root for tun devices)
sudo nix run .#awsvpnclient-service

# Terminal 2: Start GUI
nix run .#awsvpnclient
```
