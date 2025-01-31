{
  stdenv,
  lib,
  pkg-config,
  openssl,
  zlib,
  makeRustPlatform,
  fenix,
  # darwin dependencies
  darwin,
  toolchain,
}: let
  rustPlatform = makeRustPlatform {inherit (fenix.${toolchain}) cargo rustc;};

  rustPkg = fenix."${toolchain}".withComponents [
    "cargo"
    "clippy"
    "rust-src"
    "rustc"
    "rustfmt"
  ];
in
  rustPlatform.buildRustPackage
  {
    inherit
      (with builtins; (fromTOML (readFile ./Cargo.toml)).package)
      name
      version
      ;

    src = lib.cleanSource ./.;
    cargoLock.lockFile = ./Cargo.lock;
    cargoLock.outputHashes = {
      "deploy-rs-0.1.0" = "sha256-1ch9zkr3tgU/q3OLBy7m3KefVlKrQIWDRYcb9aFmOJ0=";
    };

    nativeBuildInputs = [pkg-config];
    buildInputs =
      [openssl zlib]
      ++ lib.optionals stdenv.isDarwin
      (with darwin.apple_sdk.frameworks; [
        SystemConfiguration
        Security
        CoreFoundation
        darwin.libiconv
        darwin.libresolv
        darwin.Libsystem
      ]);

    doCheck = false;

    postInstall = ''
      mkdir -p $out/share/zsh/site-functions
      $out/bin/bitte completions --shell zsh > $out/share/zsh/site-functions/_bitte

      mkdir -p $out/share/bash-completion/completions
      $out/bin/bitte completions --shell bash > $out/share/bash-completion/completions/bitte

      mkdir -p $out/share/fish/vendor_completions.d
      $out/bin/bitte completions --shell fish > $out/share/fish/vendor_completions.d/bitte.fish
    '';

    passthru = {
      inherit rustPlatform rustPkg;
      inherit (fenix.${toolchain}) rust-src;
      inherit (fenix) rust-analyzer;
    };
  }
  // {
    meta.description = "A swiss knife for the bitte cluster";
  }
