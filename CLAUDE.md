# AWS VPN Client for NixOS - Development Notes

This document captures the debugging process and key learnings for packaging the AWS VPN Client on NixOS.

## Architecture Overview

The package is split into:
- `shared.nix` - Core deb extraction and patching (used by both GUI and service)
- `application.nix` - GUI application wrapped in buildFHSEnv
- `service.nix` - Background service wrapped in buildFHSEnv
- `acvc-hook.c` - small LD_PRELOAD shim the service needs for the 5.4.0 D-Bus
  and caller-path checks (see "Version 5.4.0 workarounds" below)

## Updating the version

For a routine bump, edit `versionInfo` in `shared.nix` (`version` + `sha256`) with
the values from the [AWS Linux release notes](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-release-notes.html),
then `nix build .#awsvpnclient-service .#default`. The `.deps.json` edits, FIPS
config, and the D-Bus/caller-path workarounds are all version-independent, so a bump
should not need anything else - but AWS does add new runtime checks between releases
(5.4.0 added three; see below), so test an actual connection after upgrading.

## Key Challenges & Solutions

### 1. Musl-based OpenVPN Binaries

**Problem**: The AWS VPN Client ships with custom openvpn binaries (`acvc-openvpn`) compiled against musl libc, not glibc. Nix's `autoPatchelfHook` incorrectly patches these to use glibc, breaking them.

**Solution**: Use `buildFHSEnv` instead of `autoPatchelfHook`. The FHS environment provides libraries at standard paths without LD_PRELOAD, which would break musl binaries.

```nix
# In shared.nix - disable all ELF modifications
dontPatchELF = true;
dontStrip = true;
dontPatchShebangs = true;
nativeBuildInputs = [];
buildInputs = [];
```

### 2. Checksum Validation

**Problem**: The .NET service validates SHA256 checksums of files in `/opt/awsvpnclient/Service/Resources/openvpn/`. Any modification causes:
```
ACVC.Core.OpenVpn.OvpnResourcesChecksumValidationFailedException
```

**Solution**: Never modify files in the openvpn resources directory. This includes:
- `acvc-openvpn`
- `openssl`
- `openssl.cnf` (added to the checksum list in 5.4.0)
- `configure-dns`
- `ld-musl-x86_64.so.1`
- `fips.so`
- `libc.so`

`fipsmodule.cnf` is *generated* at build time (`openssl fipsinstall`) and is not in
the checksum list, so generating it is safe. See "FIPS enforcement" below.

### 3. Relative Interpreter Path

**Problem**: The musl openvpn binary has interpreter `ld-musl-x86_64.so.1` (relative, not absolute). The kernel resolves this from the current working directory:
- cwd=`/` → looks for `/ld-musl-x86_64.so.1`
- cwd=`/tmp` → looks for `/tmp/ld-musl-x86_64.so.1` (fails)

**Solution**:
1. Create symlink at `/ld-musl-x86_64.so.1` pointing to the real musl loader
2. Set `cd /` in the FHS profile so the service runs from root

```nix
extraBuildCommands = ''
  ln -s ${shared.exePrefix}/Service/Resources/openvpn/ld-musl-x86_64.so.1 $out/ld-musl-x86_64.so.1
'';

profile = ''
  cd /
'';
```

### 4. Read-Only Resources Directory

**Problem**: The service writes temporary config files to `/opt/awsvpnclient/Resources/`, but buildFHSEnv mounts the Nix store as read-only:
```
System.IO.IOException: Read-only file system : '/opt/awsvpnclient/Resources/...'
```

**Solution**: Mount a tmpfs on the Resources directory:
```nix
extraBwrapArgs = [
  "--tmpfs" "/opt/awsvpnclient/Resources"
];
```

### 5. Broken PATH for #!/usr/bin/env bash Scripts

**Problem**: When openvpn runs scripts via `#!/usr/bin/env bash`, the PATH becomes `/no-such-path`, causing all commands to fail:
```
mkdir: command not found
date: command not found
```

Scripts using `#!/bin/bash` work correctly (PATH is preserved).

**Root Cause**: Unknown interaction between musl openvpn, the kernel's shebang handling, and NixOS's coreutils env binary.

**Solution**: Create a custom env wrapper that fixes PATH before calling the real env:
```nix
envWrapper = pkgs.writeShellScriptBin "env" ''
  if [ -z "$PATH" ] || [ "$PATH" = "/no-such-path" ]; then
    export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:/run/current-system/sw/bin"
  fi
  exec ${pkgs.coreutils}/bin/env "$@"
'';

targetPkgs = _: with pkgs; [
  envWrapper  # Must be included to override default env
  # ...
];
```

### 6. .deps.json manifest edits (SQLite must be removed)

**Problem**: The bundled `libe_sqlite3.so` **segfaults** the process the moment the
metrics DB is opened - a hard native crash with no managed exception, so the GUI just
disappears. (Earlier this was done with pinned BOPOHA `.patch` files, but those break
on every release because `.deps.json` line numbers shift - that is what broke the
5.3.1 -> 5.4.0 bump.)

**Solution**: `shared.nix` rewrites both `.deps.json` files with `jq` (version-independent),
removing the SQLite assemblies/natives and the .NET diagnostics-only natives. With
`Microsoft.Data.Sqlite` gone from the manifest, the optional metrics code throws a
*caught* "Could not load file or assembly" exception and the app continues. Do NOT
"fix" that log error by restoring SQLite - that reintroduces the segfault. Invariant
globalization is set via `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` in both profiles
(no `runtimeconfig.json` edit needed).

### 7. FIPS enforcement

**Problem**: On connect the service runs the bundled `openssl list -providers` and
requires the FIPS provider to be `active`, otherwise:
```
ACVC.Core.OpenVpn.UnableToEnforceFipsException: Unable to enforce openvpn in fips mode.
```

**Solution**: `shared.nix` generates `fipsmodule.cnf` at build time via
`./openssl fipsinstall -out fipsmodule.cnf -module ./fips.so`. The shipped
`openssl.cnf` `.include`s it by absolute path (`/opt/awsvpnclient/...`), which resolves
correctly inside the FHS. `fipsmodule.cnf` holds only MACs (no paths), so it is
location-independent. If FIPS "is not active", first check the openssl binary actually
runs - see the LD_PRELOAD/musl note below.

## Version 5.4.0 workarounds (D-Bus + caller path)

5.4.0 re-architected the GUI<->service IPC and added two checks that the sandbox trips.
Both are handled by a single LD_PRELOAD shim, `acvc-hook.c`, compiled in `service.nix`
and preloaded onto the service via its profile. The private `dbus-daemon` and the musl
`openssl`/`openvpn` children all inherit it.

1. **Private D-Bus daemon.** The service now spawns its own `dbus-daemon`
   (`unix:abstract=awsvpnclient`) instead of using the system bus, so `dbus` must be in
   the service `targetPkgs` (`/usr/bin/dbus-daemon`). A stale instance squatting the
   abstract socket causes `Address already in use` - kill leftover `ACVC.GTK.Service`
   processes (`sudo ss -xlp | grep awsvpnclient`).

2. **Malformed `IsExclusiveAppInstance` boolean.** The service's reply encodes a bad
   boolean; the GUI throws `Read value 17 at position 4 while expecting boolean`. The
   hook's `sendmsg`/`write` interceptors (vendored from BOPOHA `hook0.c`) rewrite the
   reply boolean to true. It runs inside the dbus-daemon, which forwards both the call
   and the reply.

3. **`ValidatePidBinaryPath` caller check.** The service `readlink()`s
   `/proc/<caller>/exe` and rejects the call unless the directory is exactly
   `/opt/awsvpnclient`; in the sandbox the GUI's exe resolves to its `/nix/store` path
   (`...not in /opt/awsvpnclient`). The hook's `readlink`/`readlinkat` interceptors
   rewrite a `/proc/*/exe` target ending in `/opt/awsvpnclient/awsvpnclient` back to
   that bare path. `acvc-openvpn` and everything else are left untouched.

**CRITICAL: build the hook with FORTIFY_SOURCE disabled.** nixpkgs' `runCommandCC`
enables fortification by default, turning `fprintf`/`memcpy` into glibc's `__*_chk`
variants. musl has no `__fprintf_chk`, so every musl child (`openssl`, `acvc-openvpn`)
dies at load with `Error relocating ... __fprintf_chk: symbol not found` - which
surfaces only later as `UnableToEnforceFipsException`. The fix is
`hardeningDisable = ["fortify" "fortify3"]` plus `-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0`.
This is the same musl/glibc LD_PRELOAD hazard the rest of this doc warns about; the
shim only stays safe because it uses plain libc symbols that resolve under both.

## Testing Techniques

### Testing Inside the FHS Environment

Create a test script and inject it into the FHS wrapper:

```bash
# Create test script
cat > /tmp/my-test.sh << 'EOF'
#!/bin/bash
source /etc/profile
# Your test commands here
EOF
chmod +x /tmp/my-test.sh

# Get the service wrapper and modify it to run your test
servicePath=$(nix build .#awsvpnclient-service --no-link --print-out-paths)
cat "$servicePath/bin/awsvpnclient-service" | \
  sed 's|/nix/store/[a-z0-9]*-awsvpnclient-service-init|/tmp/my-test.sh|' > /tmp/test-wrapper.sh
chmod +x /tmp/test-wrapper.sh

# Run the test inside the FHS environment
/tmp/test-wrapper.sh
```

### Testing OpenVPN Script Execution

```bash
# Inside FHS, test if openvpn can run scripts
cat > /tmp/test-script.sh << 'SCRIPT'
#!/usr/bin/env bash
echo "PATH=$PATH" > /tmp/test-result.log
mkdir --version >> /tmp/test-result.log 2>&1
SCRIPT
chmod +x /tmp/test-script.sh

timeout 3 /opt/awsvpnclient/Service/Resources/openvpn/acvc-openvpn \
  --dev null --script-security 2 --up /tmp/test-script.sh 2>&1

cat /tmp/test-result.log
```

### Checking Interpreter

```bash
# Check what interpreter a binary uses
nix-shell -p patchelf --run "patchelf --print-interpreter /path/to/binary"
```

### Viewing Service Logs

```bash
# AWS VPN Client logs to:
tail -f /var/log/aws-vpn-client/*/gtk_service_aws_client_vpn_connect_*.log

# DNS configuration logs:
cat /var/log/aws-vpn-client/configure-dns-up.log
cat /var/log/aws-vpn-client/configure-dns-down.log
```

## DBus Requirements

As of 5.4.0 the service runs its **own** private `dbus-daemon` on
`unix:abstract=awsvpnclient` (in the shared network namespace via `--share-net`), and
the GUI connects to that. The system-bus binds below are still present but are likely
vestigial now - candidate for removal, test a full connect before dropping them:

```nix
extraBwrapArgs = [
  "--bind-try" "/run/dbus" "/run/dbus"
  "--bind-try" "/var/run/dbus" "/var/run/dbus"
];
```

See "Version 5.4.0 workarounds" for the dbus-daemon package requirement and the
`acvc-hook.c` shim that fixes the IPC.

## Required System Utilities

The service expects these at standard FHS paths:
- `ps` - /bin/ps
- `lsof` - /usr/bin/lsof
- `sysctl` - /sbin/sysctl (from procps)
- `ip` - /sbin/ip (from iproute2)
- `resolvectl` - /run/current-system/sw/bin/resolvectl (for DNS configuration)

## .NET Runtime Requirements

```nix
multiPkgs = _: with pkgs; [
  openssl
  icu74
  zlib
];

profile = ''
  export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
  export DOTNET_CLI_TELEMETRY_OPTOUT=1
'';
```

## Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `OvpnResourcesChecksumValidationFailedException` | Modified files in openvpn directory | Don't modify checksummed files |
| `OvpnProcessFailedToStartException: -1` | Interpreter not found | Ensure cwd is `/` and symlink exists |
| `Read-only file system` | Writing to Nix store | Add `--tmpfs` for writable directories |
| `could not execute external program` | Script PATH broken | Use env wrapper to fix PATH |
| `command not found` in scripts | PATH is `/no-such-path` | Use env wrapper |
| `Could not load file or assembly 'Microsoft.Data.Sqlite'` | SQLite stripped from deps.json | Expected/benign - do NOT restore SQLite (native segfault) |
| `Read value 17 ... while expecting boolean` | 5.4.0 IsExclusiveAppInstance bug | `acvc-hook.c` rewrites the reply boolean |
| `Binary path of caller PID ... not in /opt/awsvpnclient` | 5.4.0 ValidatePidBinaryPath vs sandbox | `acvc-hook.c` rewrites `/proc/*/exe` readlink |
| `UnableToEnforceFipsException` | FIPS provider not active | Check `fipsmodule.cnf` generated; ensure hook built without FORTIFY (musl `__fprintf_chk`) |
| `Error relocating ... __fprintf_chk: symbol not found` | Hook built with FORTIFY_SOURCE | `hardeningDisable=["fortify" "fortify3"]` + `-D_FORTIFY_SOURCE=0` |
| `Address already in use` (dbus) | Stale service squatting abstract socket | Kill leftover `ACVC.GTK.Service` procs |

## Version Override

The package supports overriding the version:

```nix
awsvpnclient.overrideVersion {
  version = "5.4.0";
  sha256 = "sha256-...";
}
```

## Running

```bash
# Terminal 1: Start service (requires root for tun devices)
sudo nix run .#awsvpnclient-service

# Terminal 2: Start GUI
nix run .#awsvpnclient
```
