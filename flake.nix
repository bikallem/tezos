{
  description = "Tezos NixOS developement environment using flakes";

  nixConfig.bash-prompt = "[nix-develop]$ ";

  inputs = {
    nixpkgs-21_05.url = "github:nixos/nixpkgs/nixos-21.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs-21_05, nixpkgs-unstable, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs-unstable.legacyPackages.${system};
        pkgs-21_05 = nixpkgs-21_05.legacyPackages.${system};
      in {
        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            autoconf
            rsync
            git
            m4
            patch
            unzip
            wget
            pkg-config
            pkgs-21_05.rustc
            pkgs-21_05.cargo
            pkgs-21_05.rustfmt
            gcc
            gmp
            libev
            hidapi
            libffi
            jq
            zlib
            opam
          ];

          RUST_SRC_PATH =
            "${pkgs-21_05.rust.packages.stable.rustPlatform.rustLibSrc}";
        };
      });
}
