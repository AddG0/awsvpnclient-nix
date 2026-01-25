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
  };

  config = let
    cfg = config.programs.awsvpnclient;
  in
    lib.mkIf cfg.enable {
      nixpkgs.config.permittedInsecurePackages = [
        "openssl-1.1.1w"
      ];

      environment.systemPackages = [cfg.package];

      systemd.services.awsvpnclient = {
        description = "AWS VPN Client Service";
        after = ["network.target"];
        wantedBy = ["multi-user.target"];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${cfg.servicePackage}/bin/awsvpnclient-service";
          Restart = "always";
          RestartSec = "1s";
        };
      };

      # Required for DNS resolution in AWS VPN Client
      services.resolved.enable = true;
    };
}
