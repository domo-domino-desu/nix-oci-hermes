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
      nixpkgs,
      hermes-agent,
      nix-index-database,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkSystemOutputs =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;

          imageName = "nix-for-hermes";
          hermesPackage = hermes-agent.packages.${system}.messaging;
          imageTag = hermesPackage.version;
          commaPackage = nix-index-database.packages.${system}.comma-with-db;
          realHermes = "${hermesPackage}/bin/hermes";
          containerPath = "/usr/local/bin:/bin:/usr/bin";

          # --- Base system configuration ---

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

          # Hermes is intentionally a trusted Nix client: runtime package
          # installation is a feature of this image, not a security boundary.
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

          # --- Runtime programs ---

          # Mirrors the targeted ownership contract in the pinned upstream
          # docker/stage2-hook.sh. Avoid recursively chowning unrelated files
          # that may share a bind-mounted HERMES_HOME.
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

          managedDirsWords = lib.concatMapStringsSep " " lib.escapeShellArg hermesManagedDirs;
          managedFilesWords = lib.concatMapStringsSep " " lib.escapeShellArg hermesManagedFiles;

          hermesEntrypoint = pkgs.replaceVarsWith {
            name = "hermes-entrypoint";
            src = ./scripts/hermes-entrypoint.sh.in;
            replacements = {
              inherit containerPath managedDirsWords managedFilesWords;
            };
            isExecutable = true;
          };

          hermesShim = pkgs.writeShellScript "hermes-shim" ''
            set -eu

            if [ "$(id -u)" != 0 ]; then
              exec ${lib.escapeShellArg realHermes} "$@"
            fi

            case "''${HERMES_DOCKER_EXEC_AS_ROOT:-}" in
              1|true|TRUE|True|yes|YES|Yes)
                exec ${lib.escapeShellArg realHermes} "$@"
                ;;
            esac

            export HOME="''${HOME:-/home/hermes}"
            export HERMES_HOME="''${HERMES_HOME:-/data/.hermes}"
            exec ${pkgs.s6}/bin/s6-setuidgid hermes ${lib.escapeShellArg realHermes} "$@"
          '';

          nixDaemonRun = pkgs.writeShellScript "nix-daemon-run" ''
            exec 2>&1
            export HOME=/root
            . /etc/profile.d/proxy.sh
            unset NIX_REMOTE
            exec ${pkgs.nix}/bin/nix-daemon --daemon
          '';

          hermesGatewayRun = pkgs.writeShellScript "hermes-gateway-run" ''
            exec 2>&1
            export HOME="''${HOME:-/home/hermes}"
            export HERMES_HOME="''${HERMES_HOME:-/data/.hermes}"
            export API_SERVER_ENABLED="''${API_SERVER_ENABLED:-true}"
            export API_SERVER_HOST="''${API_SERVER_HOST:-0.0.0.0}"
            export API_SERVER_PORT="''${API_SERVER_PORT:-8642}"
            export NIX_REMOTE="''${NIX_REMOTE:-daemon}"
            . /etc/profile.d/proxy.sh
            exec ${pkgs.s6}/bin/s6-setuidgid hermes ${lib.escapeShellArg realHermes} gateway run --replace
          '';

          hermesDashboardRun = pkgs.writeShellScript "hermes-dashboard-run" ''
            exec 2>&1
            export HOME="''${HOME:-/home/hermes}"
            export HERMES_HOME="''${HERMES_HOME:-/data/.hermes}"
            export GATEWAY_HEALTH_URL="''${GATEWAY_HEALTH_URL:-http://127.0.0.1:8642/health}"
            export HERMES_DASHBOARD_HOST="''${HERMES_DASHBOARD_HOST:-0.0.0.0}"
            export HERMES_DASHBOARD_PORT="''${HERMES_DASHBOARD_PORT:-9119}"
            export NIX_REMOTE="''${NIX_REMOTE:-daemon}"
            . /etc/profile.d/proxy.sh
            exec ${pkgs.s6}/bin/s6-setuidgid hermes ${lib.escapeShellArg realHermes} dashboard \
              --host "$HERMES_DASHBOARD_HOST" \
              --port "$HERMES_DASHBOARD_PORT"
          '';

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
            install -Dm0755 ${hermesEntrypoint} $out/bin/hermes-entrypoint
            install -Dm0755 ${nixDaemonRun} $out/etc/s6-services/nix-daemon/run
            install -Dm0755 ${hermesGatewayRun} $out/etc/s6-services/hermes-gateway/run
            install -Dm0755 ${hermesDashboardRun} $out/etc/s6-services/hermes-dashboard/run
          '';

          # --- Container image ---

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
              Entrypoint = [ "/bin/hermes-entrypoint" ];
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
                "PATH=${containerPath}"
              ];
              Volumes = {
                "/data" = { };
                "/home/hermes" = { };
              };
              WorkingDir = "/data";
              Healthcheck.Test = [
                "CMD-SHELL"
                "curl -fsS http://127.0.0.1:8642/health >/dev/null || exit 1"
              ];
            };
          };

          loadImage = pkgs.writeShellApplication {
            name = "load-hermes-image";
            runtimeInputs = [ pkgs.docker ];
            text = "docker load < ${dockerImage}";
          };

          composeImageTagCheck = pkgs.runCommand "check-compose-image-tag" { } ''
            ${pkgs.gnugrep}/bin/grep -Fq ${lib.escapeShellArg "image: ${imageName}:${imageTag}"} \
              ${./docker-compose.example.yaml}
            touch $out
          '';
        in
        {
          packages = {
            default = dockerImage;
            inherit
              commaPackage
              dockerImage
              hermesPackage
              runtimeRoot
              ;
          };

          apps.loadImage = {
            type = "app";
            program = "${loadImage}/bin/load-hermes-image";
            meta.description = "Load the nix-for-hermes Docker image into Docker";
          };

          checks = {
            inherit composeImageTagCheck runtimeRoot;
          };
          formatter = pkgs.nixfmt;
        };

      perSystem = forAllSystems mkSystemOutputs;
    in
    {
      packages = forAllSystems (system: perSystem.${system}.packages);
      apps = forAllSystems (system: perSystem.${system}.apps);
      checks = forAllSystems (system: perSystem.${system}.checks);
      formatter = forAllSystems (system: perSystem.${system}.formatter);
    };
}
