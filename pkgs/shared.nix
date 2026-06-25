# AWS VPN Client for NixOS - Shared Components
#
pkgs: let
  inherit (pkgs) stdenv fetchurl;

  pname = "awsvpnclient";

  # Version information
  versionInfo = {
    version = "5.4.0";
    sha256 = "7dd9e28962bf64bf94ef41b8e1f68de5e0d0393d71300767698fb336c69276cc";
  };

  srcUrl = versionInfo: "https://d20adtppz83p9s.cloudfront.net/GTK/${versionInfo.version}/awsvpnclient_amd64.deb";

  exePrefix = "/opt/awsvpnclient";
  debGuiExe = "${exePrefix}/AWS VPN Client";
  guiExe = "${exePrefix}/awsvpnclient";
  serviceExe = "${exePrefix}/Service/ACVC.GTK.Service";

  # Modeled on https://github.com/BOPOHA/aws-rpm-packages (awsvpnclient/remove-sqlite-from-deps.sh).
  #
  # Previously this used static .patch files pinned to a BOPOHA commit, but those break on every
  # AWS release because the .deps.json line numbers shift. Instead we apply the same transforms
  # programmatically with jq, so a version bump only needs `version` + `sha256` above.
  #
  # Strip the bundled SQLite assemblies/native libs (Microsoft.Data.Sqlite, SQLitePCLRaw,
  # libe_sqlite3.so) and the .NET diagnostics-only native libs (createdump, libmscordaccore.so,
  # libmscordbi.so, libcoreclrtraceptprovider.so) from the .deps.json files.
  #
  # SQLite MUST be stripped: the bundled libe_sqlite3.so segfaults the process when the metrics
  # DB is opened (a hard native crash with no managed exception). With the assembly removed from
  # the manifest, the optional metrics code instead throws a caught "Could not load file or
  # assembly" exception and the app continues normally (metrics are non-essential telemetry).
  stripDepsJq = pkgs.writeText "strip-sqlite-and-debug.jq" ''
    walk(
      if type == "object" then
        with_entries(
          (.key | ascii_downcase) as $lk
          | select(
              ($lk | contains("sqlite"))
              or (.key == "createdump")
              or (.key == "libcoreclrtraceptprovider.so")
              or (.key == "libmscordaccore.so")
              or (.key == "libmscordbi.so")
              | not
            )
        )
      else . end
    )
  '';

  mkDeb = versionInfo:
    stdenv.mkDerivation {
      pname = "${pname}-deb";
      inherit (versionInfo) version;

      src = fetchurl {
        url = srcUrl versionInfo;
        inherit (versionInfo) sha256;
      };

      # Disable ALL ELF modifications - openvpn binaries have checksum validation.
      # buildFHSEnv provides libraries at standard FHS paths, so no patching is needed.
      dontPatchELF = true; # Don't run patchelf-shrink-rpath
      dontStrip = true; # Don't strip binaries
      dontPatchShebangs = true; # Don't patch script interpreters

      nativeBuildInputs = [];
      buildInputs = [];

      unpackPhase = ''
        ${pkgs.dpkg}/bin/dpkg -x "$src" .
      '';

      buildPhase = ''
        # Strip SQLite + diagnostics natives from the .NET manifests (see stripDepsJq).
        # Invariant globalization is handled via DOTNET_SYSTEM_GLOBALIZATION_INVARIANT
        # in the GUI/service profiles, so no runtimeconfig.json edit is needed here.
        cd opt/awsvpnclient
        for deps in "AWS VPN Client.deps.json" "Service/ACVC.GTK.Service.deps.json"; do
          ${pkgs.jq}/bin/jq -f ${stripDepsJq} "$deps" > "$deps.tmp"
          mv "$deps.tmp" "$deps"
        done
        cd ../..

        # Rename to something more "linux-y"
        mv ".${debGuiExe}" ".${guiExe}"

        # Generate FIPS module config (required for service to work!)
        cd opt/awsvpnclient/Service/Resources/openvpn
        ./openssl fipsinstall -out fipsmodule.cnf -module ./fips.so
        cd ../../../../..
      '';

      installPhase = ''
        mkdir -p "$out"
        cp -r ./* "$out/"
      '';

      # No postFixup needed - buildFHSEnv provides libraries at standard FHS paths.
      # IMPORTANT: Do NOT modify openvpn binaries - the service validates their checksums.
    };
in {
  inherit pname versionInfo mkDeb;
  inherit exePrefix debGuiExe guiExe serviceExe;
}
