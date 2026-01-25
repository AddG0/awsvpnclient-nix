# AWS VPN Client for NixOS - Service
#
# This package provides the AWS VPN Client background service in an FHS environment.
# Using buildFHSEnv avoids LD_PRELOAD which breaks musl-based openvpn binaries.
# Run with: sudo nix run .#awsvpnclient-service
{
  pkgs,
  buildFHSEnv,
  shared,
  ...
}: let
  deb = shared.mkDeb shared.versionInfo;

  # Custom env wrapper that fixes PATH when it's empty or broken.
  # This is needed because openvpn clears PATH when running #!/usr/bin/env bash scripts.
  envWrapper = pkgs.writeShellScriptBin "env" ''
    # Fix PATH if it's empty or set to the broken /no-such-path
    if [ -z "$PATH" ] || [ "$PATH" = "/no-such-path" ]; then
      export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:/run/current-system/sw/bin"
    fi
    exec ${pkgs.coreutils}/bin/env "$@"
  '';
in
  buildFHSEnv {
    name = "${shared.pname}-service";
    inherit (shared.versionInfo) version;

    runScript = "${shared.serviceExe}";

    targetPkgs = _:
      with pkgs; [
        deb
        # Custom env wrapper to fix PATH for #!/usr/bin/env bash scripts
        envWrapper
        # Service expects these at standard FHS paths
        ps # /bin/ps
        lsof # /usr/bin/lsof
        procps # /sbin/sysctl
        iproute2 # /sbin/ip for routing
      ];

    # The openvpn binaries have relative interpreter "ld-musl-x86_64.so.1".
    # The kernel resolves this as /ld-musl-x86_64.so.1, so we create a symlink.
    extraBuildCommands = ''
      ln -s ${shared.exePrefix}/Service/Resources/openvpn/ld-musl-x86_64.so.1 $out/ld-musl-x86_64.so.1
    '';

    # .NET runtime requirements
    multiPkgs = _:
      with pkgs; [
        openssl
        icu74
        zlib
      ];

    extraBwrapArgs = [
      # Service needs network access
      "--share-net"
      # Service needs to create tun devices
      "--dev-bind"
      "/dev"
      "/dev"
      # Share DBus sockets for GUI communication
      "--bind-try"
      "/run/dbus"
      "/run/dbus"
      "--bind-try"
      "/var/run/dbus"
      "/var/run/dbus"
      # Service needs /run for runtime state
      "--bind-try"
      "/run"
      "/run"
      # Service writes temporary config files to /opt/awsvpnclient/Resources
      "--tmpfs"
      "/opt/awsvpnclient/Resources"
    ];

    # Set .NET environment variables and ensure openvpn can find its interpreter.
    # The openvpn binary has a relative interpreter "ld-musl-x86_64.so.1" which the
    # kernel resolves from cwd. By running from /, it finds /ld-musl-x86_64.so.1 (our symlink).
    profile = ''
      export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
      export DOTNET_CLI_TELEMETRY_OPTOUT=1
      cd /
    '';
  }
