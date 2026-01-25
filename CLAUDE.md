# AWS VPN Client for NixOS - Development Notes

This document captures the debugging process and key learnings for packaging the AWS VPN Client on NixOS.

## Architecture Overview

The package is split into three files:
- `shared.nix` - Core deb extraction and patching (used by both GUI and service)
- `application.nix` - GUI application wrapped in buildFHSEnv
- `service.nix` - Background service wrapped in buildFHSEnv

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
- `configure-dns`
- `ld-musl-x86_64.so.1`
- `fips.so`
- `libc.so`

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

The GUI and service communicate via DBus. Both need access to the system bus:

```nix
extraBwrapArgs = [
  "--bind-try" "/run/dbus" "/run/dbus"
  "--bind-try" "/var/run/dbus" "/var/run/dbus"
];
```

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
