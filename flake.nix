{
  description = "Moltis - Personal AI gateway inspired by OpenClaw";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    rust-overlay,
    crane,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        overlays = [(import rust-overlay)];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        nightly = "2025-11-30";
        wasmCraneLib =
          (crane.mkLib pkgs).overrideToolchain
          (
            p:
              p.rust-bin.nightly.${nightly}.default.override {
                targets = ["wasm32-wasip2"];
              }
          );

        # Pinned nightly to avoid recursion limit overflow in matrix-sdk
        # Latest nightly (2026-04) has query depth changes that break matrix-sdk 0.16
        rustToolchain = pkgs.rust-bin.nightly.${nightly}.default;

        rustPlatform = pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        };

        # Create a clean source that includes necessary files and the wit directory
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            (pkgs.lib.cleanSourceFilter path type)
            || (builtins.match ".*/wit.*" path != null);
        };

        # Generated web assets: Vite bundle, Tailwind CSS, service worker.
        #
        # These are gitignored, so a clean checkout has none of them, and
        # `embedded-assets` makes crates/web/build.rs exit 1 when they are
        # missing. Without this derivation `packages.default` cannot build
        # outside a working tree where `just build-web-assets` has been run.
        web-assets = pkgs.buildNpmPackage {
          pname = "moltis-web-assets";
          version = "0.1.0";
          inherit src;
          sourceRoot = "source/crates/web/ui";
          npmDepsHash = "sha256-DnQSBNBhYIAMpgw9sBGjwRVBqjWwtZ7V39nklvr/oqY=";

          # Playwright's postinstall downloads a browser: impossible in the
          # sandbox and irrelevant to the assets.
          npmFlags = ["--ignore-scripts"];

          nativeBuildInputs = [pkgs.autoPatchelfHook];
          buildInputs = [pkgs.stdenv.cc.cc.lib];

          # Rollup and Tailwind's oxide ship prebuilt .node libraries linked
          # against a glibc that is not at the usual path here. They must be
          # patched before the build runs, not in fixupPhase, so the hook is
          # invoked by hand.
          dontAutoPatchelf = true;
          preBuild = ''
            # npm brings down both the glibc and the musl build of every native
            # module. Only one of them can ever load here, and autoPatchelf
            # treats the other's missing libc as a hard error.
            find node_modules -type d -name '*-musl' -prune -exec rm -rf {} +
            autoPatchelf node_modules
          '';

          # Every script writes into ../src/assets — outside this package, and
          # exactly where include_dir! reads at compile time. Order matters:
          # build-sw.mjs hashes the asset tree, so it has to run last.
          buildPhase = ''
            runHook preBuild
            npm run build
            npm run build:css
            npm run build:shiki
            npm run build:sw
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            cp -r ../src/assets "$out"
            runHook postInstall
          '';
        };

        moltis-wasm-tools = wasmCraneLib.buildPackage {
          inherit src;
          pname = "moltis-wasm-tools";
          doCheck = false;
          cargoExtraArgs = "--target wasm32-wasip2 -p moltis-wasm-calc -p moltis-wasm-web-fetch -p moltis-wasm-web-search ";
          nativeBuildInputs = with pkgs;
            [
              rustPlatform.bindgenHook
              cmake
              perl
              pkg-config
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.libiconv
            ];
        };
      in {
        # Exposed so the asset build can be checked on its own, without
        # waiting out the Rust compile behind it.
        packages.web-assets = web-assets;

        packages.default = rustPlatform.buildRustPackage {
          pname = "moltis";
          version = "0.1.0";
          inherit src;
          doCheck = false;

          buildFeatures = [
            "embedded-assets"
            "embedded-wasm"
          ];
          preBuild = ''
            mkdir -p target/wasm32-wasip2/release/
            ln -s ${moltis-wasm-tools}/lib/* target/wasm32-wasip2/release/

            # The checkout carries only the hand-written assets; the derivation
            # above holds those plus the generated ones, so it replaces the
            # directory outright rather than being copied inside it.
            rm -rf crates/web/src/assets
            cp -r ${web-assets} crates/web/src/assets
            chmod -R u+w crates/web/src/assets
          '';
          cargoLock = {
            lockFile = ./Cargo.lock;
            outputHashes = {
              "sqlx-core-0.8.6" = "sha256-iZZlJ8YGlM1YUEGitK4aZH68tmg3y+gAVysXS8B+DW8=";
              # whatsapp-rust: the lock has a second git source, unpinned here,
              # so cargoLock rejected the whole file.
              "wacore-0.6.0" = "sha256-gjb3Lt0hMF5unxT8xTYX282wxi4aik7Vx0blxYzGF4w=";
            };
          };
          nativeBuildInputs = with pkgs; [
            rustPlatform.bindgenHook
            cmake
            perl
            pkg-config
          ];
          cargoBuildFlags = ["--bin" "moltis"];
          MOLTIS_VERSION = toString (self.shortRev or self.dirtyShortRev or self.lastModified or "nix");

          meta = with pkgs.lib; {
            description = "Personal AI gateway inspired by OpenClaw";
            homepage = "https://www.moltis.org/";
            license = licenses.mit;
            mainProgram = "moltis";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            rustPlatform.bindgenHook
            pkgs.rust-bin.nightly.${nightly}.default
            rust-analyzer
            cmake
            perl
            pkg-config
          ];
        };
      }
    );
}
