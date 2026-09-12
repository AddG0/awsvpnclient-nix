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
    meta = shared.mkMeta {
      description = "Command-line client for AWS Client VPN";
      mainProgram = "aws-vpn-client";
    };

    installPhase = ''
      install -Dm755 ${deb}${shared.cliExe} "$out${shared.cliExe}"
      mkdir -p "$out/bin"
      ln -s "$out${shared.cliExe}" "$out/bin/aws-vpn-client"
    '';

    # A phase, not postFixup: runHook evaluates the postFixup attribute before
    # postFixupHooks, so autoPatchelfHook has not run yet and the binary cannot execute.
    preDistPhases = ["genCompletionsPhase"];
    genCompletionsPhase = ''
      # The CLI makes a log dir under $HOME before parsing argv; /homeless-shelter is not writable.
      HOME=$(mktemp -d) bash ${./gen-completions.sh} "$out${shared.cliExe}" "$out"
    '';
  }
