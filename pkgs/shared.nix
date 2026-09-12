pkgs: let
  inherit (pkgs) stdenv fetchurl lib;

  pname = "awsvpnclient";

  versionInfo = {
    version = "6.0.1";
    sha256 = "c3c10d91693efa2800c4812afa7cdb0be22181fa9a2d551030fa6f4c819e8cc9";
  };

  srcUrl = versionInfo: "https://d20adtppz83p9s.cloudfront.net/GTK/${versionInfo.version}/awsvpnclient_amd64.deb";

  # The daemon hardcodes this prefix (it reads /opt/awsvpnclient/app_version and
  # runs /opt/awsvpnclient/dns/configure-dns), which is why both packages are
  # wrapped in an FHS environment rather than patchelf'd into the store.
  installPrefix = "/opt/awsvpnclient";

  # The daemon's process validator accepts a caller only if its executable is named
  # "AWS VPN Client" or "aws-vpn-client", so neither may be renamed on the way into
  # the store. See caller-path-hook.c.
  cliExe = "${installPrefix}/aws-vpn-client";
  guiExe = "${installPrefix}/AWS VPN Client";
  guiLauncher = "${installPrefix}/launch-vpn-client.sh";

  daemonExe = "${installPrefix}/aws-client-vpn-daemon";
  iconFile = "${installPrefix}/resources/app.png";

  # AWS ships no EULA in the .deb - the bundled LICENSE is Electron's MIT - but the
  # client itself is proprietary, redistributed here as a prebuilt binary.
  mkMeta = {
    description,
    mainProgram,
  }: {
    inherit description mainProgram;
    homepage = "https://aws.amazon.com/vpn/";
    downloadPage = "https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-release-notes.html";
    license = lib.licenses.unfree;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    platforms = ["x86_64-linux"];
  };

  # The GUI has no theme support at all, and this Electron build lacks Blink's
  # auto-dark feature, so rewriting these literals is the only seam. Each maps to the
  # base16 slot matching its role in the stock light theme.
  designTokens = {
    # Surfaces, lightest first.
    "#FFFFFF" = "base00";
    "#FCFCFD" = "base00";
    "#F6F6F9" = "base01";
    "#F3F3F7" = "base01";
    "#F0F0F0" = "base01";
    "#EEECF3" = "base02";
    "#EBEBF0" = "base02";
    "#E5E5E5" = "base02";
    # Borders and dividers.
    "#DEDEE3" = "base03";
    "#C6C6CD" = "base03";
    "#B4B4BB" = "base03";
    # Muted text and icon greys.
    "#A4A4AD" = "base04";
    "#8C8C94" = "base04";
    "#656871" = "base04";
    # Body text: darkest in the stock theme, so lightest here.
    "#424650" = "base05";
    "#343232" = "base05";
    "#0F141A" = "base05";
    # Accents.
    "#006CE0" = "base0D"; # primary action blue
    "#99C2F0" = "base0C"; # secondary/disabled blue
    "#00802F" = "base0B"; # connected
    "#FF9900" = "base09"; # AWS orange
  };

  # Upstream sizes the popup by formula, not content: height is min(items*36+20,204)
  # while items render 32px, and the actions menu hardcodes width 300. The window is
  # transparent so the app never notices, but the compositor borders and hit-tests the
  # full rect. Only the actions menu gets its width fitted - the profile dropdown's
  # width deliberately tracks its select box.
  dropdownFitJs = pkgs.writeText "dropdown-fit.js" (
    "g.once(\"ready-to-show\",()=>{"
    + "const w=g,p=n,fitWidth=t!==ae,upstreamWidth=c;"
    + "w.webContents.executeJavaScript('(()=>{const e=document.getElementById(\"root\"),c=e&&e.firstElementChild;if(!c)return null;const r=c.getBoundingClientRect();return [Math.ceil(r.width),Math.ceil(r.height)]})()')"
    + ".then(s=>{if(s&&s[0]>0&&s[1]>0&&!w.isDestroyed())w.setBounds({x:p.x,y:p.y,width:fitWidth?s[0]:upstreamWidth,height:s[1]})})"
    + ".catch(()=>{})"
    + ".finally(()=>{if(!w.isDestroyed()){w.show();w.focus()}})})"
  );

  # Upstream dismisses the popup only from g.on("blur"), which never fires when these
  # transparent XWayland windows fail to take focus under wlroots - and alwaysOnTop is
  # not honoured either, so it lingers behind the main window. Closing on the main
  # window's focus does not depend on the popup ever having been focused.
  dropdownCloseJs = pkgs.writeText "dropdown-close.js" (
    "i.on(\"closed\",()=>{g&&g.close(),i=null}),"
    + "i.on(\"focus\",()=>{if(g){g.close();g=null;if(T){T.webContents.send(\"dropdown-closed\");T=null}}})"
  );

  # Every token is asserted present before rewriting, so a release that reshuffles the
  # palette fails the build rather than half-theming the app.
  #
  # Three things a token swap cannot express, hence the appended stylesheet:
  #  * "#0F141A" is body text AND the text on the accent button (9 of its 38 uses), so
  #    one literal would have to become two colours. The buttons are caught instead by
  #    an attribute selector on their serialised inline background.
  #  * Chromium paints form-control popups and scrollbars from color-scheme, which the
  #    page never declares.
  #  * Its default focus ring is a near-white square box that ignores the control's
  #    shape.
  themeScript = palette: let
    slotHex = slot: "#" + lib.toUpper (lib.removePrefix "#" palette.${slot});
    calls = lib.mapAttrsToList (from: slot: "retoken '${from}' '${slotHex slot}'") designTokens;
  in ''
    retoken() {
      if ! grep -q -F "\"$1\"" asar-src/dist/assets/*.js; then
        echo "awsvpnclient: design token $1 is no longer in the renderer bundle." >&2
        echo "  Re-audit designTokens in pkgs/shared.nix against this release." >&2
        exit 1
      fi
      sed -i "s|\"$1\"|\"$2\"|g" asar-src/dist/assets/*.js
    }
    ${lib.concatStringsSep "\n    " calls}

    accent='${slotHex "base09"}'
    onAccent='${slotHex "base00"}'
    focusRing='${slotHex "base0D"}'
    accentRgb="rgb($((16#''${accent:1:2})), $((16#''${accent:3:2})), $((16#''${accent:5:2})))"

    shopt -s nullglob
    sheets=(asar-src/dist/assets/*.css)
    if [ ''${#sheets[@]} -eq 0 ]; then
      echo "awsvpnclient: no renderer stylesheet to append the theme fixups to." >&2
      exit 1
    fi
    for sheet in "''${sheets[@]}"; do
      cat >>"$sheet" <<CSS

:root{color-scheme:dark}
[style*="background: $accentRgb"],[style*="background-color: $accentRgb"]{color:$onAccent !important}
:focus-visible{outline:2px solid $focusRing;outline-offset:2px;border-radius:inherit}
CSS
    done
  '';

  mkDeb = {versionInfo}:
    stdenv.mkDerivation {
      pname = "${pname}-deb";
      inherit (versionInfo) version;

      src = fetchurl {
        url = srcUrl versionInfo;
        inherit (versionInfo) sha256;
      };

      # The daemon's RPATH starts with $ORIGIN, which is how it finds the aws-lc
      # libssl.so/libcrypto.so it ships beside itself; --shrink-rpath would drop it.
      dontPatchELF = true;
      dontStrip = true;
      dontPatchShebangs = true;

      nativeBuildInputs = [];
      buildInputs = [];

      unpackPhase = ''
        ${pkgs.dpkg}/bin/dpkg -x "$src" .
      '';

      # Only opt/. A top-level directory present in the FHS rootfs is mounted read-only
      # over the host's, so shipping the .deb's empty var/lib/awsvpnclient would leave
      # the daemon an unwritable state and log directory inside the sandbox.
      installPhase = ''
        mkdir -p "$out"
        cp -r ./opt "$out/"

        # The .deb ships these non-executable and relies on its postinst to chmod them.
        chmod +x "$out${daemonExe}" "$out${cliExe}" "$out${installPrefix}/dns/configure-dns"
      '';
    };

  # Separate from mkDeb so the daemon and CLI keep the untouched upstream tree and
  # never pay for a repack. The popup fixes apply here regardless of the palette.
  mkGuiFiles = {
    versionInfo,
    palette ? null,
  }: let
    deb = mkDeb {inherit versionInfo;};
  in
    pkgs.runCommand "${pname}-gui-${versionInfo.version}" {} ''
      src='${deb}${installPrefix}'
      dst="$out${installPrefix}"
      mkdir -p "$dst/resources"

      # Electron resolves resources/ next to the *resolved* /proc/self/exe, so a
      # symlinked executable would load the original, unpatched asar.
      for entry in "$src"/*; do
        case "$(basename "$entry")" in
          'AWS VPN Client' | resources) ;;
          *) ln -s "$entry" "$dst/" ;;
        esac
      done
      install -m755 "$src/AWS VPN Client" "$dst/AWS VPN Client"
      cp "$src/resources/app.png" "$dst/resources/"

      ${pkgs.asar}/bin/asar extract "$src/resources/app.asar" asar-src

      # --replace-fail doubles as the assertion: a release that rewrites either
      # handler stops the build instead of silently dropping the fix.
      substituteInPlace asar-src/dist-electron/main.js \
        --replace-fail 'g.once("ready-to-show",()=>{g.show()})' "$(cat ${dropdownFitJs})" \
        --replace-fail 'i.on("closed",()=>{g&&g.close(),i=null})' "$(cat ${dropdownCloseJs})"

      # The patches are textual, so parse the result before it ships.
      ${pkgs.nodejs}/bin/node --check asar-src/dist-electron/main.js

      ${lib.optionalString (palette != null) (themeScript palette)}

      # app.asar records a SHA256 per file, so it is repacked rather than byte-patched;
      # --unpack keeps daemon-client.node outside the archive for Electron to dlopen.
      ${pkgs.asar}/bin/asar pack asar-src "$dst/resources/app.asar" --unpack '*.node'
      test -f "$dst/resources/app.asar.unpacked/dist-electron/daemon-client.node"
    '';
in {
  inherit pname versionInfo mkDeb mkGuiFiles mkMeta;
  inherit installPrefix guiExe guiLauncher daemonExe cliExe iconFile;
}
