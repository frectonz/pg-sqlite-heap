{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      forAllSystems =
        fn:
        let
          systems = [
            "x86_64-linux"
            "aarch64-darwin"
          ];
          overlays = [ (import rust-overlay) ];
        in
        nixpkgs.lib.genAttrs systems (
          system:
          fn (
            import nixpkgs {
              inherit system overlays;
            }
          )
        );
    in
    {
      devShells = forAllSystems (pkgs:
      {
        default = pkgs.mkShell {
          buildInputs = [
            pkgs.bacon
            pkgs.cargo-pgrx
            pkgs.cargo-insta
            pkgs.rust-analyzer
            pkgs.rust-bin.stable.latest.default
            # Benchmarking: hyperfine for cold-path wall-clock, jq for JSON,
            # postgresql_18 puts `psql` and `pgbench` on PATH for the
            # warm-connection benchmarks.
            pkgs.hyperfine
            pkgs.jq
            pkgs.postgresql_18
            # `sqlite3` CLI: `tests/concurrency.sh` runs `PRAGMA
            # integrity_check` directly against the backing SQLite files.
            pkgs.sqlite
          ];

          inputsFrom = with pkgs; [
            postgresql_14
            postgresql_15
            postgresql_16
            postgresql_17
            postgresql_18
          ];

          nativeBuildInputs = [
            pkgs.rustPlatform.bindgenHook
          ];
        };
      });

      formatter = forAllSystems (
        pkgs:
        pkgs.treefmt.withConfig {
          runtimeInputs = [ pkgs.nixfmt ];
          settings = {
            on-unmatched = "info";
            formatter.nixfmt = {
              command = "nixfmt";
              includes = [ "*.nix" ];
            };
          };
        }
      );
    };
}
