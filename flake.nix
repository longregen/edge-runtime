{
  description = "Edge Runtime - Web APIs for Edge Computing";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }: let
    # NixOS module for edge-runtime service
    nixosModule = {
      config,
      lib,
      pkgs,
      ...
    }:
      with lib; let
        cfg = config.services.edge-runtime;
        edge-runtime = self.packages.${pkgs.system}.default;
      in {
        options.services.edge-runtime = {
          enable = mkEnableOption "Edge Runtime service";

          port = mkOption {
            type = types.port;
            default = 3000;
            description = "Port on which Edge Runtime should listen";
          };

          host = mkOption {
            type = types.str;
            default = "127.0.0.1";
            description = "Host on which Edge Runtime should listen";
          };

          script = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = "Path to the edge function script to run";
          };

          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Extra arguments to pass to edge-runtime";
          };

          environment = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = "Environment variables to set for the edge-runtime service";
          };
        };

        config = mkIf cfg.enable {
          systemd.services.edge-runtime = {
            description = "Edge Runtime service";
            wantedBy = ["multi-user.target"];
            after = ["network.target"];

            environment =
              cfg.environment
              // {
                NODE_ENV = mkDefault "production";
              };

            serviceConfig = {
              Type = "simple";
              Restart = "always";
              RestartSec = 10;

              ExecStart =
                "${edge-runtime}/bin/edge-runtime"
                + optionalString (cfg.script != null) " --listen --host ${cfg.host} --port ${toString cfg.port} ${cfg.script}"
                + optionalString (cfg.extraArgs != []) (" " + concatStringsSep " " cfg.extraArgs);

              # Security hardening
              NoNewPrivileges = true;
              DynamicUser = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ReadWritePaths = [];
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
              LockPersonality = true;
              RestrictRealtime = true;
            };
          };
        };
      };
  in
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      nodejs = pkgs.nodejs_20;

      # Helper function to build individual Edge Runtime packages from the main build
      buildEdgeRuntimePackage = packageName: let
        packagePath = "packages/${packageName}";
        packageJson = builtins.fromJSON (builtins.readFile "${./.}/${packagePath}/package.json");
      in
        pkgs.runCommand "${packageJson.name}-${packageJson.version}" {
          meta = with pkgs.lib; {
            description = packageJson.description or "Edge Runtime package: ${packageName}";
            homepage = packageJson.homepage or "https://edge-runtime.vercel.app";
            license = licenses.mit;
            maintainers = [];
            platforms = platforms.unix;
          };
        } ''
          mkdir -p $out/lib/node_modules/${packageJson.name}

          # Copy from the main edge-runtime build
          if [ -d ${edge-runtime}/lib/edge-runtime/${packagePath}/dist ]; then
            cp -r ${edge-runtime}/lib/edge-runtime/${packagePath}/dist $out/lib/node_modules/${packageJson.name}/
          fi

          if [ -d ${edge-runtime}/lib/edge-runtime/${packagePath}/src ]; then
            cp -r ${edge-runtime}/lib/edge-runtime/${packagePath}/src $out/lib/node_modules/${packageJson.name}/
          fi

          # Copy the package.json
          cp ${edge-runtime}/lib/edge-runtime/${packagePath}/package.json $out/lib/node_modules/${packageJson.name}/

          # Create package info
          echo "Edge Runtime package: ${packageJson.name}" > $out/lib/node_modules/${packageJson.name}/README.md
          echo "Built from workspace at ${packagePath}" >> $out/lib/node_modules/${packageJson.name}/README.md
        '';

      # Build edge-runtime using pnpm hooks
      edge-runtime = pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "edge-runtime";
        version = "4.0.1";

        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = name: type: let
            baseName = baseNameOf name;
          in
            !(pkgs.lib.hasInfix ".pnpm-store" name)
            && !(baseName == "node_modules")
            && !(baseName == "result")
            && !(pkgs.lib.hasSuffix ".log" baseName)
            && !(pkgs.lib.hasSuffix ".nix" baseName);
        };

        nativeBuildInputs = with pkgs; [
          nodejs
          pnpm_9.configHook
          npmHooks.npmBuildHook
          npmHooks.npmInstallHook
          makeWrapper
          python3 # For node-gyp
        ];

        buildInputs = [nodejs];

        # Fetch dependencies using pnpm
        pnpmDeps = pkgs.pnpm_9.fetchDeps {
          inherit (finalAttrs) pname version src;
          hash = "sha256-exNgM1NnqljHLG5YJtWFWUz96PVn43Hvyuu4WYq6RX0=";
        };

        # Use frozen lockfile for reproducibility
        pnpmInstallFlags = ["--frozen-lockfile"];

        # Override npm build/install hooks to use pnpm
        preBuild = ''
          export PATH="${pkgs.pnpm_9}/bin:$PATH"
          pnpm rebuild
        '';

        buildPhase = ''
          runHook preBuild
          pnpm build
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/lib/edge-runtime

          cp -r packages $out/lib/edge-runtime/
          cp -r node_modules $out/lib/edge-runtime/
          cp -r docs $out/lib/edge-runtime/
          cp package.json $out/lib/edge-runtime/
          cp pnpm-workspace.yaml $out/lib/edge-runtime/
          cp pnpm-lock.yaml $out/lib/edge-runtime/

          mkdir -p $out/bin

          makeWrapper ${nodejs}/bin/node $out/bin/edge-runtime \
            --add-flags "$out/lib/edge-runtime/packages/runtime/dist/cli/index.js" \
            --prefix NODE_PATH : "$out/lib/edge-runtime/node_modules" \
            --set NODE_ENV "production"

          runHook postInstall
        '';

        meta = with pkgs.lib; {
          description = "Run any Edge Function from CLI or Node.js module";
          homepage = "https://edge-runtime.vercel.app";
          license = licenses.mit;
          maintainers = [];
          platforms = platforms.unix;
          mainProgram = "edge-runtime";
        };
      });
      # Individual Edge Runtime packages
      edgeRuntimePackages = {
        cookies = buildEdgeRuntimePackage "cookies";
        format = buildEdgeRuntimePackage "format";
        jest-environment = buildEdgeRuntimePackage "jest-environment";
        jest-expect = buildEdgeRuntimePackage "jest-expect";
        node-utils = buildEdgeRuntimePackage "node-utils";
        ponyfill = buildEdgeRuntimePackage "ponyfill";
        primitives = buildEdgeRuntimePackage "primitives";
        runtime = buildEdgeRuntimePackage "runtime";
        types = buildEdgeRuntimePackage "types";
        user-agent = buildEdgeRuntimePackage "user-agent";
        vm = buildEdgeRuntimePackage "vm";
      };
    in {
      packages =
        {
          default = edge-runtime;
          edge-runtime = edge-runtime;
        }
        // edgeRuntimePackages;

      # Expose edgeRuntimePackages as a separate output for convenience
      edgeRuntimePackages = edgeRuntimePackages;

      devShells.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nodejs
          pnpm_9
          typescript
          python3
          git
        ];
      };

      apps = {
        default = {
          type = "app";
          program = "${edge-runtime}/bin/edge-runtime";
        };

        edge-runtime = {
          type = "app";
          program = "${edge-runtime}/bin/edge-runtime";
        };
      };
      checks = {
        nixos-vm-test = pkgs.nixosTest {
          name = "edge-runtime-nixos-test";
          nodes.machine = {...}: {
            imports = [self.nixosModules.default];
            services.edge-runtime.enable = true;
            services.edge-runtime.script = pkgs.writeText "test.js" ''
              /* global addEventListener, Response */

              addEventListener('fetch', (event) => {
                return event.respondWith(new Response('hello from nixos'))
              })
            '';
            networking.firewall.allowedTCPPorts = [3000];
          };
          testScript = ''
            machine.wait_for_unit("edge-runtime.service")
            machine.wait_for_open_port(3000)
            response = machine.succeed("curl -s http://localhost:3000/")
            assert "hello from nixos" in response
          '';
        };
      };
    })
    // {
      nixosModules = {
        default = nixosModule;
        edge-runtime = nixosModule;
      };
    };
}
