perSystem: {lib, config, ...}: {
  imports =
    map (
      opt:
        lib.mkRenamedOptionModule ["programs" "awsvpnclient" opt] ["services" "awsvpnclient" opt]
    ) ["enable" "servicePackage" "cliPackage" "palette"]
    ++ [
      (lib.mkRenamedOptionModule ["programs" "awsvpnclient" "package"] ["services" "awsvpnclient" "guiPackage"])
    ];

  options.services.awsvpnclient = {
    enable = lib.mkEnableOption "the AWS VPN Client daemon, CLI and GUI";

    guiPackage = lib.mkOption {
      type = lib.types.package;
      default = perSystem.config.packages.default;
      description = "The awsvpnclient GUI package to use.";
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

    installGui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        Install the GUI system-wide. Set to `false` when installing it through the
        home-manager module instead, which is where a per-user palette lives.

        Leaving this `true` alongside the home-manager module installs the GUI twice -
        once themed, once not - and `$PATH` order decides which one launches.
      '';
    };

    palette = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      # Guarded on stylix.enable rather than on stylix being imported: lib.stylix.colors
      # throws unless a scheme is set, so the looser test breaks hosts that never set one.
      default =
        if config.stylix.enable or false
        then config.lib.stylix.colors
        else null;
      defaultText = lib.literalMD "`config.lib.stylix.colors` when Stylix is enabled, otherwise `null`";
      example = lib.literalExpression ''config.lib.stylix.colors // {base04 = "a6adc8";}'';
      description = ''
        base16 palette used to recolour the GUI. The upstream Electron app is
        light-only and has no theme support, so its hardcoded colours are rewritten at
        build time. Only `base00`-`base05`, `base09`, `base0B`, `base0C` and `base0D`
        are read. Set to `null` to keep upstream's colours.

        Muted text comes from `base04`, which base16 leaves free to be a status-bar
        tone rather than a foreground - it ranges from 2.1:1 to 9.2:1 against `base00`
        across schemes. Override that one slot if muted text looks washed out.

        A release that reshuffles the upstream colours fails the build rather than
        theming the app halfway.
      '';
    };
  };

  config = let
    cfg = config.services.awsvpnclient;
    themedGui =
      if cfg.palette == null
      then cfg.guiPackage
      else cfg.guiPackage.override {base16Palette = cfg.palette;};
  in
    lib.mkIf cfg.enable {
      environment.systemPackages = lib.optional cfg.installGui themedGui ++ [cfg.cliPackage];

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

      # dns/configure-dns shells out to resolvectl, which needs resolved running.
      services.resolved.enable = true;
    };
}
