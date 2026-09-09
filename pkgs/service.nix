# The privileged daemon. Needs an FHS environment because it resolves several paths
# under a hardcoded /opt/awsvpnclient prefix.
{
  pkgs,
  buildFHSEnv,
  shared,
  ...
}: let
  deb = shared.mkDeb {inherit (shared) versionInfo;};

  # Makes the daemon's caller check accept the sandboxed GUI/CLI - see
  # caller-path-hook.c. FORTIFY_SOURCE is disabled because the hook defines libc
  # symbols that glibc's fortified headers redirect to __*_chk variants.
  callerPathHook =
    pkgs.runCommandCC "awsvpnclient-caller-path-hook" {
      hardeningDisable = ["fortify" "fortify3"];
    } ''
      mkdir -p $out/lib
      $CC -shared -fPIC -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
        -o $out/lib/caller-path-hook.so ${./caller-path-hook.c} -ldl
    '';
in
  buildFHSEnv {
    name = "${shared.pname}-service";
    inherit (shared.versionInfo) version;

    runScript = "${shared.daemonExe}";

    targetPkgs = _:
      with pkgs; [
        deb
        # dns/configure-dns calls these by absolute path: /usr/bin/{mkdir,rm,date}
        # and /usr/bin/resolvectl, which talks to the host's systemd-resolved over
        # the bind-mounted system bus.
        coreutils
        systemd
        # The daemon shells out to /sbin/ip for routing table operations.
        iproute2
      ];

    # No extraBwrapArgs: buildFHSEnv already shares the host network namespace, /dev,
    # and every host directory the rootfs does not provide, /run included.

    profile = ''
      export LD_PRELOAD="${callerPathHook}/lib/caller-path-hook.so''${LD_PRELOAD:+:$LD_PRELOAD}"
    '';
  }
