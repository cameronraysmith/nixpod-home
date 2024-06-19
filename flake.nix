{
  description = "A portable flake for Nix-based development when you cannot necessarily use NixOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    catppuccin.url = "github:catppuccin/nix";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixos-flake.url = "github:srid/nixos-flake";
    flocken = {
      url = "github:mirkolenz/flocken/v2";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.systems.follows = "systems";
    };

    # see https://github.com/nix-systems/default/blob/main/default.nix
    systems.url = "github:nix-systems/default";
  };

  outputs =
    inputs @ { self
    , ...
    }:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;
      imports = [
        inputs.nixos-flake.flakeModule
        ./home
      ];

      perSystem = { self', inputs', pkgs, system, ... }:
        let
          # users = {
          #   root = {
          #     name = "root";
          #     uid = "0";
          #     gid = "0";
          #   };
          #   runner = {
          #     name = "runner";
          #     uid = "1001";
          #     gid = "121";
          #   };
          #   jovyan = {
          #     name = "jovyan";
          #     uid = "1000";
          #     gid = "100";
          #   };
          # };
          users = [ "root" "jovyan" "runner" ];
          myUserName = "runner";
          myUserUid = "1001";
          myUserGid = "121";
          includedSystems =
            let
              envVar = builtins.getEnv "NIX_IMAGE_SYSTEMS";
            in
            if envVar == ""
            then [ "x86_64-linux" "aarch64-linux" ]
            else builtins.filter (sys: sys != "") (builtins.split " " envVar);
          buildMultiUserNixImage = import ./containers/multiuser.nix;
        in
        {
          legacyPackages = {
            # Make home-manager configuration
            # homeConfigurations.${myUserName} = homeConfig;
            homeConfigurations = builtins.listToAttrs (map
              (user: {
                name = user;
                value = self.nixos-flake.lib.mkHomeConfiguration
                  pkgs
                  ({ pkgs, ... }: {
                    imports = [
                      inputs.self.homeModules.default
                      inputs.catppuccin.homeManagerModules.catppuccin
                    ];
                    home.username = user;
                    home.homeDirectory =
                      if user == "root"
                      then "/root"
                      else "/${
                      if pkgs.stdenv.isDarwin
                      then "Users"
                      else "home"
                      }/${user}";
                    home.stateVersion = "23.11";
                  });
              })
              users);

            # Combine OCI json for includedSystems and push to registries
            nixpodManifest = inputs'.flocken.legacyPackages.mkDockerManifest {
              github = {
                enable = true;
                enableRegistry = false;
                token = "$GH_TOKEN";
              };
              autoTags = {
                branch = false;
              };
              registries = {
                "ghcr.io" = {
                  enable = true;
                  repo = "cameronraysmith/nixpod";
                  username = builtins.getEnv "GITHUB_ACTOR";
                  password = "$GH_TOKEN";
                };
              };
              version = builtins.getEnv "VERSION";
              images = builtins.map (sys: self.packages.${sys}.container) includedSystems;
              tags = [
                (builtins.getEnv "GIT_SHA_SHORT")
                (builtins.getEnv "GIT_SHA")
                (builtins.getEnv "GIT_REF")
              ];
            };

            ghanixManifest = inputs'.flocken.legacyPackages.mkDockerManifest {
              github = {
                enable = true;
                enableRegistry = false;
                token = "$GH_TOKEN";
              };
              autoTags = {
                branch = false;
              };
              registries = {
                "ghcr.io" = {
                  enable = true;
                  repo = "cameronraysmith/ghanix";
                  username = builtins.getEnv "GITHUB_ACTOR";
                  password = "$GH_TOKEN";
                };
              };
              version = builtins.getEnv "VERSION";
              images = builtins.map (sys: self.packages.${sys}.ghanix) includedSystems;
              tags = [
                (builtins.getEnv "GIT_SHA_SHORT")
                (builtins.getEnv "GIT_SHA")
                (builtins.getEnv "GIT_REF")
              ];
            };

            jupnixManifest = inputs'.flocken.legacyPackages.mkDockerManifest {
              github = {
                enable = true;
                enableRegistry = false;
                token = "$GH_TOKEN";
              };
              autoTags = {
                branch = false;
              };
              registries = {
                "ghcr.io" = {
                  enable = true;
                  repo = "cameronraysmith/jupnix";
                  username = builtins.getEnv "GITHUB_ACTOR";
                  password = "$GH_TOKEN";
                };
              };
              version = builtins.getEnv "VERSION";
              images = builtins.map (sys: self.packages.${sys}.jupnix) includedSystems;
              tags = [
                (builtins.getEnv "GIT_SHA_SHORT")
                (builtins.getEnv "GIT_SHA")
                (builtins.getEnv "GIT_REF")
              ];
            };
          };

          # Enable 'nix fmt' to lint with nixpkgs-fmt
          formatter = pkgs.nixpkgs-fmt;

          # Enable 'nix run' to activate home-manager.
          apps.default.program = self'.packages.activate-home;

          # Enable 'nix develop' to activate the development shell.
          devShells.default = pkgs.mkShell {
            name = "nixpod";
            nativeBuildInputs = with pkgs; [
              act
              just
              ratchet
            ];
          };

          packages = rec {
            # Enable 'nix build' to build the home configuration, without
            # activating it.
            default = self'.legacyPackages.homeConfigurations.${myUserName}.activationPackage;
            activate = self'.packages.activate-home;

            pamImage = pkgs.dockerTools.buildImage {
              name = "pamimage";
              tag = "latest";

              copyToRoot = pkgs.pam;

              runAsRoot = ''
                #!${pkgs.runtimeShell}

                mkdir -p /etc/pam.d
              '';
            };

            suImage = pkgs.dockerTools.buildImage {
              name = "suimage";
              tag = "latest";
              fromImage = pamImage;

              copyToRoot = pkgs.su;
            };

            sudoImage = import ./containers/sudoimage.nix {
              inherit pkgs suImage;
            };

            nixImage = buildMultiUserNixImage {
              inherit pkgs;
              name = "multiusernix";
              tag = "latest";
              maxLayers = 70;
              fromImage = sudoImage;
              extraPkgs = with pkgs; [
                ps
                s6
                su
                sudo
                tree
                vim
              ];
              nixConf = {
                allowed-users = [ "*" ];
                experimental-features = [ "nix-command" "flakes" ];
                max-jobs = [ "auto" ];
                sandbox = "false";
                trusted-users = [ "root" "jovyan" "runner" ];
              };
            };

            # Enable 'nix run .#container to build an OCI tarball with the 
            # home configuration activated.
            container = nixpod;
            nixpod = pkgs.dockerTools.buildLayeredImage {
              name = "nixpod";
              tag = "latest";
              created = "now";
              fromImage = nixImage;
              maxLayers = 111;
              contents = with pkgs; [
                default
              ];
              config = {
                Entrypoint = [ "/opt/scripts/entrypoint.sh" ];
                Cmd = [ "/root/.nix-profile/bin/bash" ];
                Env = [
                  #   "NIX_REMOTE=daemon"
                ];
              };
            };

            ghanix = buildMultiUserNixImage {
              inherit pkgs;
              name = "ghanix";
              tag = "latest";
              maxLayers = 111;
              fromImage = sudoImage;
              storeOwner = {
                uid = 1001;
                gid = 0;
                uname = "runner";
                gname = "wheel";
              };
              extraPkgs = with pkgs; [
                ps
                s6
                su
                sudo
                tree
                vim
              ];
              extraContents = [
                self'.legacyPackages.homeConfigurations.runner.activationPackage
              ];
              extraFakeRootCommands = ''
                chown -R runner:wheel /nix
              '';
              nixConf = {
                allowed-users = [ "*" ];
                experimental-features = [ "nix-command" "flakes" ];
                max-jobs = [ "auto" ];
                sandbox = "false";
                trusted-users = [ "root" "jovyan" "runner" ];
              };
              cmd = [
                "bash"
                "-c"
                "su runner -c /activate && su runner && bash"
              ];
            };

            jupnix = buildMultiUserNixImage {
              inherit pkgs;
              name = "jupnix";
              tag = "latest";
              maxLayers = 111;
              fromImage = sudoImage;
              storeOwner = {
                uid = 1000;
                gid = 0;
                uname = "jovyan";
                gname = "wheel";
              };
              extraPkgs = with pkgs; [
                ps
                s6
                su
                sudo
                tree
                vim
              ];
              extraContents = [
                self'.legacyPackages.homeConfigurations.jovyan.activationPackage
              ];
              extraFakeRootCommands = ''
                chown -R jovyan:wheel /nix
              '';
              nixConf = {
                allowed-users = [ "*" ];
                experimental-features = [ "nix-command" "flakes" ];
                max-jobs = [ "auto" ];
                sandbox = "false";
                trusted-users = [ "root" "jovyan" "runner" ];
              };
              cmd = [
                "bash"
                "-c"
                "su jovyan -c /activate && su jovyan && bash"
              ];
            };
          };

          # `nix run .#update` vs `nix flake update`
          nixos-flake = {
            primary-inputs = [
              "nixpkgs"
              "home-manager"
              "nixos-flake"
            ];
          };
        };
    };
}
