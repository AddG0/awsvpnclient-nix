# AWS VPN Client for NixOS - Shared Components
#
pkgs: let
  inherit (pkgs) lib stdenv fetchurl;

  pname = "awsvpnclient";

  # Version information
  versionInfo = {
    version = "5.3.1";
    sha256 = "4a426cc226382748d683a4946340447dab87ec42583977d9488ee45d11cdcec0";
  };

  srcUrl = versionInfo: "https://d20adtppz83p9s.cloudfront.net/GTK/${versionInfo.version}/awsvpnclient_amd64.deb";

  exePrefix = "/opt/awsvpnclient";
  debGuiExe = "${exePrefix}/AWS VPN Client";
  guiExe = "${exePrefix}/awsvpnclient";
  serviceExe = "${exePrefix}/Service/ACVC.GTK.Service";

  # https://github.com/BOPOHA/aws-rpm-packages/tree/51c6a0569dab2761b4a83361c0f5173ed00ef8ee
  patchPrefix = "https://raw.githubusercontent.com/BOPOHA/aws-rpm-packages/51c6a0569dab2761b4a83361c0f5173ed00ef8ee/awsvpnclient";
  patchInfos = [
    {
      url = "${patchPrefix}/acvc.gtk..deps.patch";
      sha256 = "sha256-TB3KavtX+lNdCx3IhQYsAJTBmpIVhDYqHrwYM2Te3HM=";
    }
    {
      url = "${patchPrefix}/awsvpnclient.deps.patch";
      sha256 = "sha256-Eehpbz7S62PfXtdURVX3FrLTITYtEFVrP8sxPRJMadQ=";
    }
    {
      url = "${patchPrefix}/awsvpnclient.runtimeconfig.patch";
      sha256 = "sha256-+EZlLWSprpYkECjd0RyK1NmlJOoylS1A/+ry+AoUAcE=";
    }
  ];

  fetchedPatches = map (patch:
    fetchurl {
      inherit (patch) url sha256;
    })
  patchInfos;

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
        # Apply source patches
        cd opt/awsvpnclient
        ${lib.concatStringsSep "\n" (map (patch: ''
            cp ${patch} tmp.patch
            sed -i -E 's|([+-]{3}) (\")?/opt/awsvpnclient/|\1 \2./|g' tmp.patch
            patch -p1 < tmp.patch
            rm tmp.patch
          '')
          fetchedPatches)}
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
