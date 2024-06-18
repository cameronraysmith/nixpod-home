{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, name ? "nix"
, tag ? "latest"
, bundleNixpkgs ? true
, channelName ? "nixpkgs"
, channelURL ? "https://nixos.org/channels/nixpkgs-unstable"
, extraPkgs ? [ pkgs.s6 ]
, maxLayers ? 100
, nixConf ? { }
, flake-registry ? null
, fromImage ? null
}:
let
  defaultPkgs = with pkgs; [
    nix
    bashInteractive
    coreutils-full
    gnutar
    gzip
    gnugrep
    which
    curl
    less
    wget
    man
    cacert.out
    findutils
    iana-etc
    git
    openssh
  ] ++ extraPkgs;

  nonRootUsers = {
    jovyan = {
      uid = 1000;
      shell = "${pkgs.bashInteractive}/bin/bash";
      home = "/home/jovyan";
      gid = 100;
      groups = [ "root" "jovyan" "wheel" ];
      description = "Privileged Jupyter user";
    };

    runner = {
      uid = 1001;
      shell = "${pkgs.bashInteractive}/bin/bash";
      home = "/home/runner";
      gid = 121;
      groups = [ "root" "runner" "wheel" ];
      description = "Privileged GitHub Actions user";
    };
  };

  users = {
    root = {
      uid = 0;
      shell = "${pkgs.bashInteractive}/bin/bash";
      home = "/root";
      gid = 0;
      groups = [ "root" ];
      description = "System administrator";
    };

    nobody = {
      uid = 65534;
      shell = "${pkgs.shadow}/bin/nologin";
      home = "/var/empty";
      gid = 65534;
      groups = [ "nobody" ];
      description = "Unprivileged account (don't use!)";
    };
  } // nonRootUsers
  // lib.listToAttrs (
    map
      (
        n: {
          name = "nixbld${toString n}";
          value = {
            uid = 30000 + n;
            gid = 30000;
            groups = [ "nixbld" ];
            description = "Nix build user ${toString n}";
          };
        }
      )
      (lib.lists.range 1 32)
  );

  groups = {
    root.gid = 0;
    wheel.gid = 1;
    jovyan.gid = 100;
    runner.gid = 121;
    nixbld.gid = 30000;
    nobody.gid = 65534;
  };

  userToPasswd = (
    k:
    { uid
    , gid ? 65534
    , home ? "/var/empty"
    , description ? ""
    , shell ? "/bin/false"
    , groups ? [ ]
    }: "${k}:x:${toString uid}:${toString gid}:${description}:${home}:${shell}"
  );
  passwdContents = (
    lib.concatStringsSep "\n"
      (lib.attrValues (lib.mapAttrs userToPasswd users))
  );

  userToShadow = k: { ... }: "${k}:!:1::::::";
  shadowContents = (
    lib.concatStringsSep "\n"
      (lib.attrValues (lib.mapAttrs userToShadow users))
  );

  # Map groups to members
  # {
  #   group = [ "user1" "user2" ];
  # }
  groupMemberMap = (
    let
      # Create a flat list of user/group mappings
      mappings = (
        builtins.foldl'
          (
            acc: user:
              let
                groups = users.${user}.groups or [ ];
              in
              acc ++ map
                (group: {
                  inherit user group;
                })
                groups
          )
          [ ]
          (lib.attrNames users)
      );
    in
    (
      builtins.foldl'
        (
          acc: v: acc // {
            ${v.group} = acc.${v.group} or [ ] ++ [ v.user ];
          }
        )
        { }
        mappings)
  );

  groupToGroup = k: { gid }:
    let
      members = groupMemberMap.${k} or [ ];
    in
    "${k}:x:${toString gid}:${lib.concatStringsSep "," members}";
  groupContents = (
    lib.concatStringsSep "\n"
      (lib.attrValues (lib.mapAttrs groupToGroup groups))
  );

  defaultNixConf = {
    sandbox = "false";
    build-users-group = "nixbld";
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
  };

  nixConfContents = (lib.concatStringsSep "\n" (lib.mapAttrsFlatten
    (n: v:
      let
        vStr = if builtins.isList v then lib.concatStringsSep " " v else v;
      in
      "${n} = ${vStr}")
    (defaultNixConf // nixConf))) + "\n";

  nonRootUserDirectories = pkgs.runCommand "create-user-directories" { } ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: attrs:
      ''
      mkdir -p $out/${attrs.home}
      chown -R ${toString attrs.uid}:${toString attrs.gid} $out/${attrs.home}
      ''
    ) nonRootUsers)}
  '';

  baseSystem =
    let
      nixpkgs = pkgs.path;
      channel = pkgs.runCommand "channel-nixos" { inherit bundleNixpkgs; } ''
        mkdir $out
        if [ "$bundleNixpkgs" ]; then
          ln -s ${nixpkgs} $out/nixpkgs
          echo "[]" > $out/manifest.nix
        fi
      '';
      rootEnv = pkgs.buildPackages.buildEnv {
        name = "root-profile-env";
        paths = defaultPkgs;
      };
      manifest = pkgs.buildPackages.runCommand "manifest.nix" { } ''
        cat > $out <<EOF
        [
        ${lib.concatStringsSep "\n" (builtins.map (drv: let
          outputs = drv.outputsToInstall or [ "out" ];
        in ''
          {
            ${lib.concatStringsSep "\n" (builtins.map (output: ''
              ${output} = { outPath = "${lib.getOutput output drv}"; };
            '') outputs)}
            outputs = [ ${lib.concatStringsSep " " (builtins.map (x: "\"${x}\"") outputs)} ];
            name = "${drv.name}";
            outPath = "${drv}";
            system = "${drv.system}";
            type = "derivation";
            meta = { };
          }
        '') defaultPkgs)}
        ]
        EOF
      '';
      profile = pkgs.buildPackages.runCommand "user-environment" { } ''
        mkdir $out
        cp -a ${rootEnv}/* $out/
        ln -s ${manifest} $out/manifest.nix
      '';
      flake-registry-path =
        if (flake-registry == null) then
          null
        else if (builtins.readFileType (toString flake-registry)) == "directory" then
          "${flake-registry}/flake-registry.json"
        else
          flake-registry;
      s6EntrypointScript = pkgs.writeShellScript "entrypoint.sh" ''
        #!${pkgs.runtimeShell}
        exec ${pkgs.s6}/bin/s6-svscan /etc/services.d
      '';
      nixDaemonService = pkgs.writeShellScript "nix-daemon-run" ''
        #!${pkgs.runtimeShell}
        exec ${pkgs.nix}/bin/nix-daemon
      '';
      nixProfileScript = pkgs.writeShellScript "nix.sh" ''
        # Nix
        if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
            . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
        fi
        # End Nix
      '';
    in
    pkgs.runCommand "base-system"
      {
        inherit passwdContents groupContents shadowContents nixConfContents;
        passAsFile = [
          "passwdContents"
          "groupContents"
          "shadowContents"
          "nixConfContents"
        ];
        allowSubstitutes = false;
        preferLocalBuild = true;
      }
      (''
        env
        set -x
        mkdir -p $out/etc

        mkdir -p $out/etc/ssl/certs
        ln -s /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs

        cat $passwdContentsPath > $out/etc/passwd
        echo "" >> $out/etc/passwd

        cat $groupContentsPath > $out/etc/group
        echo "" >> $out/etc/group

        cat $shadowContentsPath > $out/etc/shadow
        echo "" >> $out/etc/shadow

        mkdir -p $out/usr
        ln -s /nix/var/nix/profiles/share $out/usr/

        mkdir -p $out/nix/var/nix/gcroots

        mkdir $out/tmp

        mkdir -p $out/var/tmp

        mkdir -p $out/etc/nix
        cat $nixConfContentsPath > $out/etc/nix/nix.conf

        mkdir -p $out/home/jovyan
        mkdir -p $out/home/runner
        mkdir -p $out/root
        mkdir -p $out/nix/var/nix/profiles/per-user/root

        ln -s ${profile} $out/nix/var/nix/profiles/default-1-link
        ln -s $out/nix/var/nix/profiles/default-1-link $out/nix/var/nix/profiles/default
        ln -s /nix/var/nix/profiles/default $out/root/.nix-profile

        ln -s ${channel} $out/nix/var/nix/profiles/per-user/root/channels-1-link
        ln -s $out/nix/var/nix/profiles/per-user/root/channels-1-link $out/nix/var/nix/profiles/per-user/root/channels

        mkdir -p $out/root/.nix-defexpr
        ln -s $out/nix/var/nix/profiles/per-user/root/channels $out/root/.nix-defexpr/channels
        echo "${channelURL} ${channelName}" > $out/root/.nix-channels

        mkdir -p $out/bin $out/usr/bin
        ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env
        ln -s ${pkgs.bashInteractive}/bin/bash $out/bin/sh

        mkdir -p $out/opt/scripts
        ln -s ${s6EntrypointScript} $out/opt/scripts/entrypoint.sh

        mkdir -p $out/etc/services.d/nix-daemon
        ln -s ${nixDaemonService} $out/etc/services.d/nix-daemon/run
      '' + (lib.optionalString (flake-registry-path != null) ''
        nixCacheDir="/root/.cache/nix"
        mkdir -p $out$nixCacheDir
        globalFlakeRegistryPath="$nixCacheDir/flake-registry.json"
        ln -s ${flake-registry-path} $out$globalFlakeRegistryPath
        mkdir -p $out/nix/var/nix/gcroots/auto
        rootName=$(${pkgs.nix}/bin/nix --extra-experimental-features nix-command hash file --type sha1 --base32 <(echo -n $globalFlakeRegistryPath))
        ln -s $globalFlakeRegistryPath $out/nix/var/nix/gcroots/auto/$rootName
      ''));

in
pkgs.dockerTools.buildLayeredImageWithNixDb {

  inherit name tag maxLayers fromImage;

  contents = [ baseSystem ];

  extraCommands = ''
    rm -rf nix-support
    ln -s /nix/var/nix/profiles nix/var/nix/gcroots/profiles
  '';
  fakeRootCommands = ''
    chmod 1777 tmp
    chmod 1777 var/tmp
    chown -R runner:runner home/runner
    chown -R jovyan:jovyan home/jovyan
  '';

  config = {
    Cmd = [ "/root/.nix-profile/bin/bash" ];
    Env = [
      "USER=root"
      "PATH=${lib.concatStringsSep ":" [
        "/root/.nix-profile/bin"
        "/nix/var/nix/profiles/default/bin"
        "/nix/var/nix/profiles/default/sbin"
      ]}"
      "MANPATH=${lib.concatStringsSep ":" [
        "/root/.nix-profile/share/man"
        "/nix/var/nix/profiles/default/share/man"
      ]}"
      "SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt"
      "NIX_PATH=/nix/var/nix/profiles/per-user/root/channels:/root/.nix-defexpr/channels"
    ];
  };

}
