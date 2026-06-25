# AWS VPN Client for NixOS - Service
#
# This package provides the AWS VPN Client background service in an FHS environment.
# buildFHSEnv provides libraries at standard paths without autoPatchelf, which would
# rewrite the musl-based openvpn binaries. (A narrowly-scoped LD_PRELOAD shim is used
# for the 5.4.0 D-Bus/caller-path workarounds - see acvc-hook.c - which the openvpn
# binaries tolerate without modification.)
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

  # Compiled shim that works around two 5.4.0 behaviours (D-Bus boolean reply
  # + ValidatePidBinaryPath caller check). See acvc-hook.c for the full rationale.
  # It is LD_PRELOADed into the service via the profile below; the dbus-daemon and
  # the musl openvpn/openssl children inherit it and must be able to load it too.
  #
  # FORTIFY_SOURCE MUST be disabled: it rewrites fprintf/memcpy into glibc's
  # __*_chk variants, which musl does not provide. With fortify on, every musl
  # child (openssl, acvc-openvpn) dies at load with "Error relocating ...
  # __fprintf_chk: symbol not found", which surfaces as UnableToEnforceFipsException.
  # Plain libc symbols resolve fine under both glibc and musl, so the hook becomes
  # a harmless no-op in the musl processes.
  acvcHook = pkgs.runCommandCC "awsvpnclient-acvc-hook" {
    hardeningDisable = ["fortify" "fortify3"];
  } ''
    mkdir -p $out/lib
    $CC -shared -fPIC -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
      -o $out/lib/acvc-hook.so ${./acvc-hook.c} -ldl
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
        dbus # /usr/bin/dbus-daemon - service spawns its own private bus (5.4.0+)
      ];

    # The openvpn binaries have relative interpreter "ld-musl-x86_64.so.1".
    # The kernel resolves this as /ld-musl-x86_64.so.1, so we create a symlink.
    # Also pre-create the ConnectionInfoFiles directory so bwrap has a mount
    # point for the tmpfs below (the .deb doesn't ship this dir).
    extraBuildCommands = ''
      ln -s ${shared.exePrefix}/Service/Resources/openvpn/ld-musl-x86_64.so.1 $out/ld-musl-x86_64.so.1
      mkdir -p $out/opt/awsvpnclient/ConnectionInfoFiles
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
      # Service writes per-connection info files here (keyed by openvpn PID).
      # If this is read-only, the disconnect path hangs in the GUI's
      # "Sending SIGTERM to OpenVPN" DBus call to ACVC.GTK.Service.
      "--tmpfs"
      "/opt/awsvpnclient/ConnectionInfoFiles"
    ];

    # Set .NET environment variables and ensure openvpn can find its interpreter.
    # The openvpn binary has a relative interpreter "ld-musl-x86_64.so.1" which the
    # kernel resolves from cwd. By running from /, it finds /ld-musl-x86_64.so.1 (our symlink).
    profile = ''
      export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
      export DOTNET_CLI_TELEMETRY_OPTOUT=1
      # Preload the 5.4.0 D-Bus / caller-path workaround shim (see acvc-hook.c).
      # Inherited by the private dbus-daemon and openvpn children.
      export LD_PRELOAD="${acvcHook}/lib/acvc-hook.so''${LD_PRELOAD:+:$LD_PRELOAD}"
      cd /
    '';
  }
