# The unprivileged Electron GUI. Reaches the daemon over its socket in /run.
{
  pkgs,
  buildFHSEnv,
  makeDesktopItem,
  shared,
  # base16 palette (hex, leading '#' optional); null keeps upstream's colours.
  # NOT named `palette`: nixpkgs has a package by that name, so callPackage would
  # inject the package and shadow this default.
  base16Palette ? null,
  ...
}: let
  desktopItem = makeDesktopItem {
    name = "AWS VPN Client";
    desktopName = "AWS VPN Client";
    exec = "awsvpnclient %U";
    icon = "awsvpnclient";
    comment = "AWS VPN Client provides secure VPN connectivity";
    categories = ["Network" "X-VPN"];
    keywords = ["vpn" "aws" "amazon" "connect"];
    startupWMClass = "AWS VPN Client";
  };

  guiFHS = versionInfo: let
    guiFiles = shared.mkGuiFiles {
      inherit versionInfo;
      palette = base16Palette;
    };
  in
    buildFHSEnv {
      name = shared.pname;
      inherit (versionInfo) version;

      # AWS's own launcher, which forces X11/XWayland rendering and points Electron
      # at the session bus. The daemon's process validator matches on the caller's
      # executable name, so the binary it execs must keep the name "AWS VPN Client".
      runScript = "${shared.guiLauncher}";

      targetPkgs = _:
        with pkgs; [
          guiFiles
          # Electron's DT_NEEDED libraries - a superset of the .deb's Depends: line.
          alsa-lib
          at-spi2-atk
          at-spi2-core
          atk
          cairo
          cups
          dbus
          expat
          gdk-pixbuf
          glib
          gtk3
          libdrm
          libgbm
          libGL
          libnotify
          libxkbcommon
          mesa
          nspr
          nss
          pango
          udev
          xorg.libX11
          xorg.libXcomposite
          xorg.libXdamage
          xorg.libXext
          xorg.libXfixes
          xorg.libXrandr
          xorg.libXScrnSaver
          xorg.libxcb
          xorg.libXtst
        ];

      # /run - where the GUI finds the daemon's socket - is bind-mounted from the
      # host by buildFHSEnv already, so no extraBwrapArgs are needed.

      extraInstallCommands = ''
        mkdir -p "$out/share/applications"
        cp "${desktopItem}/share/applications/AWS VPN Client.desktop" "$out/share/applications/AWS VPN Client.desktop"

        mkdir -p "$out/share/icons/hicolor/256x256/apps"
        cp "${guiFiles}${shared.iconFile}" "$out/share/icons/hicolor/256x256/apps/awsvpnclient.png"
      '';
    };

  # Support for .overrideVersion { version = "x.y.z"; sha256 = "..."; }
  makeOverridable = f: origArgs: let
    origRes = f origArgs;
  in
    origRes // {overrideVersion = newArgs: (f (origArgs // newArgs));};
in
  makeOverridable guiFHS shared.versionInfo
