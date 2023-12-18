{
  description = "A portable flake for Nix-based development when you cannot necessarily use NixOS";

  inputs = {
    # Principle inputs (updated by `nix run .#update`)
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    home-manager.url = "github:nix-community/home-manager/release-23.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    nixos-flake.url = "github:srid/nixos-flake";
    nix2container.url = "github:nlewo/nix2container";

    # see https://github.com/nix-systems/default/blob/main/default.nix
    systems.url = "github:nix-systems/default";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        inputs.nixos-flake.flakeModule
        ./home
      ];

      perSystem = { self', pkgs, system, ... }:
        let
          myUserName = "runner";
          homeDir =
            if myUserName == "root"
            then "/root"
            else "/${
            if pkgs.stdenv.isDarwin
            then "Users"
            else "home"
          }/${myUserName}";
          homeConfig = inputs.self.nixos-flake.lib.mkHomeConfiguration
            pkgs
            ({ pkgs, ... }: {
              imports = [ inputs.self.homeModules.default ];
              home.username = myUserName;
              home.homeDirectory = homeDir;
              home.stateVersion = "23.11";
            });
          inherit (inputs.nix2container.packages.${system}.nix2container) buildImage;
        in
        {
          # Make home-manager configuration
          legacyPackages.homeConfigurations.${myUserName} = homeConfig;

          # Enable 'nix fmt' to lint with nixpkgs-fmt
          formatter = pkgs.nixpkgs-fmt;

          # Enable 'nix run' to activate home-manager.
          apps.default.program = self'.packages.activate-home;

          # Enable 'nix develop' to activate the development shell.
          devShells.default = pkgs.mkShell {
            name = "nixpod-home";
            nativeBuildInputs = with pkgs; [ just ];
          };

          # Enable 'nix build' to build the home configuration, without activating.
          packages.default = self'.legacyPackages.homeConfigurations.${myUserName}.activationPackage;

          # Enable 'nix run .#container to compile the home configuration into OCI json.
          packages.container = buildImage {
            name = "nixpod-home";
            tag = "latest";
            copyToRoot = [
              homeConfig.activationPackage
            ];
            config = {
              Cmd = [
                "${pkgs.bash}/bin/bash"
                "-c"
                "${self'.packages.activate-home}/bin/activate-home && exec ${pkgs.zsh}/bin/zsh"
              ];
            };
          };
        };
    };
}
