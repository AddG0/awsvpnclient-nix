# AWS VPN Client for NixOS - GUI Application
#
# This package provides the AWS VPN Client GUI wrapped in an FHS environment.
# Run with: nix run .#awsvpnclient
{
  pkgs,
  buildFHSEnv,
  makeDesktopItem,
  shared,
  ...
}: let
  mkDesktopItem = makeDesktopItem {
    name = "AWS VPN Client";
    desktopName = "AWS VPN Client";
    exec = "awsvpnclient %u";
    icon = "awsvpnclient";
    categories = ["Network" "X-VPN"];
    startupWMClass = "AWS VPN Client";
  };

  guiFHS = versionInfo: let
    deb = shared.mkDeb versionInfo;
    desktopItem = mkDesktopItem;
  in
    buildFHSEnv {
      name = shared.pname;
      inherit (versionInfo) version;

      runScript = "${shared.guiExe}";
      targetPkgs = _:
        with pkgs; [
          deb
          # AWS VPN Client expects /sbin/ip for routing table operations
          iproute2
        ];

      multiPkgs = _: with pkgs; [openssl icu74 gtk3 zstd];

      extraBwrapArgs = [
        # Share DBus sockets for service communication
        "--ro-bind-try"
        "/run/dbus"
        "/run/dbus"
        "--ro-bind-try"
        "/var/run/dbus"
        "/var/run/dbus"
      ];

      extraInstallCommands = ''
        mkdir -p "$out/share/applications"
        cp "${desktopItem}/share/applications/AWS VPN Client.desktop" "$out/share/applications/AWS VPN Client.desktop"

        # Install icon to hicolor theme (required for KDE Plasma app menu)
        mkdir -p "$out/share/icons/hicolor/64x64/apps"
        cp "${deb}/usr/share/pixmaps/acvc-64.png" "$out/share/icons/hicolor/64x64/apps/awsvpnclient.png"
      '';
    };

  # Support for .overrideVersion { version = "x.y.z"; sha256 = "..."; }
  makeOverridable = f: origArgs: let
    origRes = f origArgs;
  in
    origRes // {overrideVersion = newArgs: (f (origArgs // newArgs));};
in
  makeOverridable guiFHS shared.versionInfo
