# awsvpnclient-nix

AWS VPN Client for NixOS.

## Usage

Add to your flake inputs:

```nix
{
  inputs.awsvpnclient-nix = {
    url = "github:AddG0/awsvpnclient-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Import the module and enable:

```nix
{
  nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
    modules = [
      awsvpnclient-nix.nixosModules.default
      {
        programs.awsvpnclient.enable = true;
      }
    ];
  };
}
```

## Disclaimer

This is an unofficial community package. AWS and AWS VPN Client are trademarks of Amazon.com, Inc. or its affiliates. This project is not affiliated with, endorsed by, or sponsored by Amazon Web Services.

## References

- [AWS Client VPN for Linux release notes](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-release-notes.html) — versions, dates, and sha256 for each `.deb`
