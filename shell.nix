{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  buildInputs = with pkgs; [ 
    rsync
    git 
    m4
    patch
    unzip
    wget
    pkg-config
    rustc
    cargo
    gcc
    rustfmt 
    gmp
    libev
    hidapi
    libffi
    jq
    zlib
    opam
  ];

  RUST_SRC_PATH = "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
}

