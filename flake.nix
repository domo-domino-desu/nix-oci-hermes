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

      runtimeRoot = pkgs.runCommand "nix-for-hermes-runtime-root" { } ''
        mkdir -p \
          $out/bin \
          $out/etc/nix \
          $out/etc/profile.d \
          $out/etc/s6-services/nix-daemon \
          $out/etc/s6-services/hermes-gateway \
          $out/etc/s6-services/hermes-dashboard \
          $out/root \
          $out/tmp \
          $out/var/tmp \
          $out/data \
          $out/home/hermes \
          $out/nix/var/nix/daemon-socket \
          $out/nix/var/nix/db \
          $out/nix/var/nix/gcroots/per-user/hermes \
          $out/nix/var/nix/profiles/per-user/hermes \
          $out/nix/var/log/nix/drvs

        cat > $out/etc/passwd <<'EOF'
        root:x:0:0:root:/root:/bin/sh
        hermes:x:10000:10000:Hermes Agent:/home/hermes:/bin/sh
        EOF

        cat > $out/etc/group <<'EOF'
        root:x:0:
        hermes:x:10000:
        EOF

        cat > $out/etc/nsswitch.conf <<'EOF'
        hosts: files dns
        passwd: files
        group: files
        shadow: files
        EOF

        cat > $out/etc/nix/nix.conf <<'EOF'
        experimental-features = nix-command flakes
        sandbox = false
        build-users-group =
        allowed-users = *
        trusted-users = root hermes
        substituters = https://cache.nixos.org/
        trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
        EOF

        cat > $out/etc/profile.d/proxy.sh <<'EOF'
        # Keep upper/lowercase proxy variables in sync for interactive shells.
        if [ -n "''${HTTP_PROXY:-}" ] && [ -z "''${http_proxy:-}" ]; then export http_proxy="$HTTP_PROXY"; fi
        if [ -n "''${http_proxy:-}" ] && [ -z "''${HTTP_PROXY:-}" ]; then export HTTP_PROXY="$http_proxy"; fi
        if [ -n "''${HTTPS_PROXY:-}" ] && [ -z "''${https_proxy:-}" ]; then export https_proxy="$HTTPS_PROXY"; fi
        if [ -n "''${https_proxy:-}" ] && [ -z "''${HTTPS_PROXY:-}" ]; then export HTTPS_PROXY="$https_proxy"; fi
        if [ -n "''${ALL_PROXY:-}" ] && [ -z "''${all_proxy:-}" ]; then export all_proxy="$ALL_PROXY"; fi
        if [ -n "''${all_proxy:-}" ] && [ -z "''${ALL_PROXY:-}" ]; then export ALL_PROXY="$all_proxy"; fi
        if [ -n "''${NO_PROXY:-}" ] && [ -z "''${no_proxy:-}" ]; then export no_proxy="$NO_PROXY"; fi
        if [ -n "''${no_proxy:-}" ] && [ -z "''${NO_PROXY:-}" ]; then export NO_PROXY="$no_proxy"; fi
        EOF

        cat > $out/bin/hermes-image-entrypoint <<'EOF'
        #!/bin/sh
        set -eu

        export PATH="/bin:/usr/bin:/run/current-system/sw/bin:$PATH"

        if [ -r /etc/profile.d/proxy.sh ]; then
          . /etc/profile.d/proxy.sh
        fi

        mkdir -p \
          /data/.hermes \
          /home/hermes \
          /tmp \
          /var/tmp \
          /nix/var/nix/daemon-socket \
          /nix/var/nix/db \
          /nix/var/nix/gcroots/per-user/hermes \
          /nix/var/nix/profiles/per-user/hermes \
          /nix/var/log/nix/drvs

        chmod 1777 /tmp /var/tmp
        chmod -R u+rwX /data /home/hermes
        chmod -R u+rwX /nix/var/nix /nix/var/log/nix
        chown -R hermes:hermes /data /home/hermes /nix/var/nix/gcroots/per-user/hermes /nix/var/nix/profiles/per-user/hermes
        chmod -R u+rwX /data /home/hermes
        chmod -R u+rwX /nix/var/nix/gcroots/per-user/hermes /nix/var/nix/profiles/per-user/hermes

        if [ -e /data/.hermes/.env ] && ! s6-setuidgid hermes sh -c 'test -r /data/.hermes/.env'; then
          echo "Hermes cannot read /data/.hermes/.env after ownership repair." >&2
          echo "Check the host bind mount permissions for ./data/.hermes/.env." >&2
          ls -ld /data /data/.hermes /data/.hermes/.env >&2 || true
          exit 1
        fi

        if [ "$#" -gt 0 ]; then
          exec "$@"
        fi

        exec s6-svscan /etc/s6-services
        EOF
        chmod 0755 $out/bin/hermes-image-entrypoint

        cat > $out/etc/s6-services/nix-daemon/run <<'EOF'
        #!/bin/sh
        exec 2>&1
        export HOME=/root
        . /etc/profile.d/proxy.sh
        unset NIX_REMOTE
        exec nix-daemon --daemon
        EOF
        chmod 0755 $out/etc/s6-services/nix-daemon/run

        cat > $out/etc/s6-services/hermes-gateway/run <<'EOF'
        #!/bin/sh
        exec 2>&1
        export HOME="''${HOME:-/home/hermes}"
        export HERMES_HOME="''${HERMES_HOME:-/data/.hermes}"
        export API_SERVER_ENABLED="''${API_SERVER_ENABLED:-true}"
        export API_SERVER_HOST="''${API_SERVER_HOST:-0.0.0.0}"
        export API_SERVER_PORT="''${API_SERVER_PORT:-8642}"
        export NIX_REMOTE="''${NIX_REMOTE:-daemon}"
        . /etc/profile.d/proxy.sh
        exec s6-setuidgid hermes hermes gateway run --replace
        EOF
        chmod 0755 $out/etc/s6-services/hermes-gateway/run

        cat > $out/etc/s6-services/hermes-dashboard/run <<'EOF'
        #!/bin/sh
        exec 2>&1
        export HOME="''${HOME:-/home/hermes}"
        export HERMES_HOME="''${HERMES_HOME:-/data/.hermes}"
        export GATEWAY_HEALTH_URL="''${GATEWAY_HEALTH_URL:-http://127.0.0.1:8642/health}"
        export HERMES_DASHBOARD_HOST="''${HERMES_DASHBOARD_HOST:-0.0.0.0}"
        export HERMES_DASHBOARD_PORT="''${HERMES_DASHBOARD_PORT:-9119}"
        export NIX_REMOTE="''${NIX_REMOTE:-daemon}"
        . /etc/profile.d/proxy.sh
        exec s6-setuidgid hermes hermes dashboard --host "$HERMES_DASHBOARD_HOST" --port "$HERMES_DASHBOARD_PORT"
        EOF
        chmod 0755 $out/etc/s6-services/hermes-dashboard/run
      '';

      imagePackages = with pkgs; [
        bashInteractive
        cacert
        commaPackage
        coreutils
        curl
        findutils
        gawk
        git
        gnugrep
        gnused
        gzip
        hermesPackage
        iproute2
        jq
        nix
        openssh
        procps
        ripgrep
        s6
        s6-rc
        shadow
        stdenv.cc.cc.lib
        gnutar
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
            "PATH=/bin:/usr/bin"
          ];
          Volumes = {
            "/data" = { };
            "/home/hermes" = { };
            "/nix" = { };
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
        inherit dockerImage runtimeRoot;
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
