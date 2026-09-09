# The command-line client. Unlike the GUI and daemon it needs no FHS environment:
# it resolves nothing under the install prefix.
{
  stdenv,
  autoPatchelfHook,
  shared,
  ...
}: let
  deb = shared.mkDeb {inherit (shared) versionInfo;};
in
  stdenv.mkDerivation {
    pname = "aws-vpn-client";
    inherit (shared.versionInfo) version;

    dontUnpack = true;
    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [stdenv.cc.cc.lib];

    # The daemon validates callers by the tail of their /proc/<pid>/exe, so the binary
    # has to keep its install-prefix layout.
    installPhase = ''
      install -Dm755 ${deb}${shared.cliExe} "$out${shared.cliExe}"
      mkdir -p "$out/bin"
      ln -s "$out${shared.cliExe}" "$out/bin/aws-vpn-client"
    '';
  }
