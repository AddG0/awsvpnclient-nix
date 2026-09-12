{
  lib,
  config,
  pkgs,
  ...
}: let
  shared = import ./pkgs/shared.nix pkgs;
in {
  options.programs.awsvpnclient = {
    enable = lib.mkEnableOption "the AWS VPN Client GUI for this user";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./pkgs/application.nix {inherit shared;};
      defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/application.nix { }";
      description = "The awsvpnclient GUI package to use.";
    };

    palette = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      # Guarded on stylix.enable: lib.stylix.colors throws unless a scheme is set.
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

      '';
    };
  };

  config = let
    cfg = config.programs.awsvpnclient;
  in
    lib.mkIf cfg.enable {
      # Set services.awsvpnclient.installGui = false, or the GUI installs twice and
      # $PATH decides which one runs.
      home.packages = [
        (
          if cfg.palette == null
          then cfg.package
          else cfg.package.override {base16Palette = cfg.palette;}
        )
      ];
    };
}
