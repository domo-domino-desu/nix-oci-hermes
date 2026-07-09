{
  description = "Nix-generated Hermes Agent Docker image with runtime nixpkgs access";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    hermes-agent = {
      url = "github:NousResearch/hermes-agent/7ecc822e1165f5f4d274075a40066a8ab04214d0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      hermes-agent,
      nix-index-database,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
      };

      imageName = "nix-for-hermes";
      imageTag = "0.18.2";

      hermesPackage = hermes-agent.packages.${system}.messaging;
      commaPackage = nix-index-database.packages.${system}.comma-with-db;
      lib = pkgs.lib;
      containerPath = "/usr/local/bin:/bin:/usr/bin";

      passwdFile = pkgs.writeText "nix-for-hermes-passwd" ''
        root:x:0:0:root:/root:/bin/sh
        hermes:x:10000:10000:Hermes Agent:/home/hermes:/bin/sh
      '';

      groupFile = pkgs.writeText "nix-for-hermes-group" ''
        root:x:0:
        hermes:x:10000:
      '';

      nsswitchFile = pkgs.writeText "nix-for-hermes-nsswitch.conf" ''
        hosts: files dns
        passwd: files
        group: files
        shadow: files
      '';

      nixConfFile = pkgs.writeText "nix-for-hermes-nix.conf" ''
        experimental-features = nix-command flakes
        sandbox = false
        build-users-group =
        allowed-users = *
        trusted-users = root hermes
        substituters = https://cache.nixos.org/
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      '';

      proxyProfile = pkgs.writeText "nix-for-hermes-proxy.sh" ''
        # Keep upper/lowercase proxy variables in sync for interactive shells.
        if [ -n "''${HTTP_PROXY:-}" ] && [ -z "''${http_proxy:-}" ]; then export http_proxy="$HTTP_PROXY"; fi
        if [ -n "''${http_proxy:-}" ] && [ -z "''${HTTP_PROXY:-}" ]; then export HTTP_PROXY="$http_proxy"; fi
        if [ -n "''${HTTPS_PROXY:-}" ] && [ -z "''${https_proxy:-}" ]; then export https_proxy="$HTTPS_PROXY"; fi
        if [ -n "''${https_proxy:-}" ] && [ -z "''${HTTPS_PROXY:-}" ]; then export HTTPS_PROXY="$https_proxy"; fi
        if [ -n "''${ALL_PROXY:-}" ] && [ -z "''${all_proxy:-}" ]; then export all_proxy="$ALL_PROXY"; fi
        if [ -n "''${all_proxy:-}" ] && [ -z "''${ALL_PROXY:-}" ]; then export ALL_PROXY="$all_proxy"; fi
        if [ -n "''${NO_PROXY:-}" ] && [ -z "''${no_proxy:-}" ]; then export no_proxy="$NO_PROXY"; fi
        if [ -n "''${no_proxy:-}" ] && [ -z "''${NO_PROXY:-}" ]; then export NO_PROXY="$no_proxy"; fi
      '';

      hermesManagedDirs = [
        "backups"
        "cron"
        "sessions"
        "logs"
        "logs/gateways"
        "hooks"
        "memories"
        "skills"
        "skins"
        "plans"
        "workspace"
        "home"
        "profiles"
        "pairing"
        "platforms/pairing"
        "lazy-packages"
      ];

      hermesManagedFiles = [
        "auth.json"
        "auth.lock"
        ".env"
        "config.yaml"
        "state.db"
        "state.db-shm"
        "state.db-wal"
        "hermes_state.db"
        "response_store.db"
        "response_store.db-shm"
        "response_store.db-wal"
        "gateway.pid"
        "gateway.lock"
        "gateway_state.json"
        "processes.json"
        "active_profile"
      ];

      executableTemplate =
        name: src: replacements:
        pkgs.replaceVarsWith {
          inherit name src replacements;
          isExecutable = true;
        };

      realHermes = "${hermesPackage}/bin/hermes";
      managedDirsWords = lib.concatMapStringsSep " " lib.escapeShellArg hermesManagedDirs;
      managedFilesWords = lib.concatMapStringsSep " " lib.escapeShellArg hermesManagedFiles;

      hermesShim = executableTemplate "nix-for-hermes-hermes-shim" ./files/hermes-shim.sh.in {
        inherit realHermes;
      };

      hermesImageEntrypoint =
        executableTemplate "hermes-image-entrypoint" ./files/hermes-image-entrypoint.sh.in
          {
            inherit containerPath managedDirsWords managedFilesWords;
          };

      nixDaemonRun = ./files/nix-daemon-run.sh;

      hermesGatewayRun = executableTemplate "hermes-gateway-run" ./files/hermes-gateway-run.sh.in {
        inherit realHermes;
      };

      hermesDashboardRun = executableTemplate "hermes-dashboard-run" ./files/hermes-dashboard-run.sh.in {
        inherit realHermes;
      };

      runtimeDirectories = [
        "/bin"
        "/etc/nix"
        "/etc/profile.d"
        "/etc/s6-services/nix-daemon"
        "/etc/s6-services/hermes-gateway"
        "/etc/s6-services/hermes-dashboard"
        "/root"
        "/tmp"
        "/usr/local/bin"
        "/var/tmp"
        "/data/.hermes"
        "/home/hermes"
        "/nix/var/nix/daemon-socket"
        "/nix/var/nix/db"
        "/nix/var/nix/gcroots/per-user/hermes"
        "/nix/var/nix/profiles/per-user/hermes"
        "/nix/var/log/nix/drvs"
      ];

      runtimeRoot = pkgs.runCommand "nix-for-hermes-runtime-root" { } ''
        mkdir -p ${lib.concatMapStringsSep " " (path: "$out${path}") runtimeDirectories}

        install -Dm0644 ${passwdFile} $out/etc/passwd
        install -Dm0644 ${groupFile} $out/etc/group
        install -Dm0644 ${nsswitchFile} $out/etc/nsswitch.conf
        install -Dm0644 ${nixConfFile} $out/etc/nix/nix.conf
        install -Dm0644 ${proxyProfile} $out/etc/profile.d/proxy.sh

        install -Dm0755 ${hermesShim} $out/usr/local/bin/hermes
        install -Dm0755 ${hermesImageEntrypoint} $out/bin/hermes-image-entrypoint
        install -Dm0755 ${nixDaemonRun} $out/etc/s6-services/nix-daemon/run
        install -Dm0755 ${hermesGatewayRun} $out/etc/s6-services/hermes-gateway/run
        install -Dm0755 ${hermesDashboardRun} $out/etc/s6-services/hermes-dashboard/run
      '';

      imagePackages = with pkgs; [
        bashInteractive
        cacert
        chromium
        commaPackage
        coreutils
        curl
        findutils
        gawk
        git
        gnugrep
        gnused
        gnutar
        gzip
        hermesPackage
        iproute2
        jq
        nix
        nodejs_22
        openssh
        procps
        ripgrep
        s6
        s6-rc
        shadow
        stdenv.cc.cc.lib
        xz
      ];

      dockerImage = pkgs.dockerTools.buildLayeredImage {
        name = imageName;
        tag = imageTag;
        contents = [
          pkgs.dockerTools.binSh
          pkgs.dockerTools.usrBinEnv
        ]
        ++ imagePackages;
        extraCommands = ''
          cp -a ${runtimeRoot}/. .
        '';
        fakeRootCommands = ''
          chmod 1777 ./tmp ./var/tmp
          chown -R 10000:10000 ./data ./home/hermes
          chmod -R u+rwX,go-rwx ./data ./home/hermes
          chown -R 10000:10000 ./nix/var/nix/gcroots/per-user/hermes ./nix/var/nix/profiles/per-user/hermes
          chmod -R u+rwX,go-rwx ./nix/var/nix/gcroots/per-user/hermes ./nix/var/nix/profiles/per-user/hermes
        '';
        maxLayers = 120;
        config = {
          Entrypoint = [ "/bin/hermes-image-entrypoint" ];
          ExposedPorts = {
            "8642/tcp" = { };
            "9119/tcp" = { };
          };
          Env = [
            "HOME=/home/hermes"
            "HERMES_HOME=/data/.hermes"
            "API_SERVER_ENABLED=true"
            "API_SERVER_HOST=0.0.0.0"
            "API_SERVER_PORT=8642"
            "NIX_REMOTE=daemon"
            "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "PATH=/usr/local/bin:/bin:/usr/bin"
          ];
          Volumes = {
            "/data" = { };
            "/home/hermes" = { };
          };
          WorkingDir = "/data";
          Healthcheck = {
            Test = [
              "CMD-SHELL"
              "curl -fsS http://127.0.0.1:8642/health >/dev/null || exit 1"
            ];
          };
        };
      };

      loadImage = pkgs.writeShellApplication {
        name = "load-hermes-image";
        runtimeInputs = [ pkgs.docker ];
        text = ''
          docker load < ${dockerImage}
        '';
      };
    in
    {
      packages.${system} = {
        default = dockerImage;
        inherit
          commaPackage
          dockerImage
          hermesPackage
          runtimeRoot
          ;
      };

      apps.${system}.loadImage = {
        type = "app";
        program = "${loadImage}/bin/load-hermes-image";
        meta.description = "Load the nix-for-hermes Docker image into Docker";
      };

      checks.${system} = {
        inherit runtimeRoot;
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
