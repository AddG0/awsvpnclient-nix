perSystem: {lib, config, ...}: {
  options.programs.awsvpnclient = {
    enable = lib.mkEnableOption "Enable AWS VPN Client";

    package = lib.mkOption {
      type = lib.types.package;
      default = perSystem.config.packages.default;
      description = "The awsvpnclient package to use.";
    };

    servicePackage = lib.mkOption {
      type = lib.types.package;
      default = perSystem.config.packages.awsvpnclient-service;
      description = "The awsvpnclient-service package to use.";
    };

    cliPackage = lib.mkOption {
      type = lib.types.package;
      default = perSystem.config.packages.awsvpnclient-cli;
      description = "The aws-vpn-client CLI package to use.";
    };

    palette = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default =
        if config ? lib && config.lib ? stylix
        then config.lib.stylix.colors
        else null;
      defaultText = lib.literalMD "`config.lib.stylix.colors` when Stylix is present, otherwise `null`";
      description = ''
        base16 palette used to recolour the GUI. The upstream Electron app is
        light-only and has no theme support, so its hardcoded design tokens are
        rewritten at build time; only `base00`-`base05`, `base09`, `base0B`,
        `base0C` and `base0D` are read. Set to `null` to keep upstream's colours.

        A version bump that reshuffles those tokens fails the build rather than
        theming the app halfway - see `designTokens` in `pkgs/shared.nix`.
      '';
    };
  };

  config = let
    cfg = config.programs.awsvpnclient;
    guiPackage =
      if cfg.palette == null
      then cfg.package
      else cfg.package.override {base16Palette = cfg.palette;};
  in
    lib.mkIf cfg.enable {
      environment.systemPackages = [guiPackage cfg.cliPackage];

      systemd.services.awsvpnclient = {
        description = "AWS VPN Client Daemon";
        after = ["network.target"];
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.servicePackage}/bin/awsvpnclient-service";
          Restart = "always";
          RestartSec = "1s";

          # The daemon binds its IPC socket here; letting systemd own the directory
          # also clears the stale socket when the daemon stops.
          RuntimeDirectory = "awsvpnclient";
          RuntimeDirectoryMode = "0755";
          # The daemon refuses to use its state directory unless it is exactly 0700
          # ("Directory has insecure permissions: 755, expected 700").
          StateDirectory = "awsvpnclient";
          StateDirectoryMode = "0700";
        };
      };

      # Required for DNS resolution in AWS VPN Client
      services.resolved.enable = true;
    };
}
