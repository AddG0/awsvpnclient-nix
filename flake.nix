{
  description = "AWS VPN Client for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
      systems = ["x86_64-linux"];

      flake.nixosModules = {
        awsvpnclient = moduleWithSystem (perSystem@{config, ...}: import ./nixos-module.nix perSystem);
        default = inputs.self.nixosModules.awsvpnclient;
      };

      flake.homeModules = {
        awsvpnclient = moduleWithSystem (perSystem@{config, ...}: import ./home-module.nix perSystem);
        default = inputs.self.homeModules.awsvpnclient;
      };

      perSystem = {pkgs, ...}: let
        shared = import ./pkgs/shared.nix pkgs;
      in {
        packages = rec {
          default = awsvpnclient;
          awsvpnclient = pkgs.callPackage ./pkgs/application.nix {inherit shared;};
          awsvpnclient-service = pkgs.callPackage ./pkgs/service.nix {inherit shared;};
          awsvpnclient-cli = pkgs.callPackage ./pkgs/cli.nix {inherit shared;};
        };
      };
    });
}
