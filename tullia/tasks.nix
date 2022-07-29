{rev ? "HEAD", ...}: let
  common = {
    config,
    lib,
    ...
  }: {
    preset = {
      nix.enable = true;
      github-ci = __mapAttrs (_: lib.mkDefault) {
        enable = config.action.facts != {};
        repo = "input-output-hk/bitte";
        sha = config.preset.github-ci.lib.getRevision "GitHub event" rev;
        clone = false;
      };
    };
  };

  flakeUrl = {
    config,
    lib,
    ...
  }:
    lib.escapeShellArg (
      if config.action.facts != {}
      then "github:${config.preset.github-ci.repo}/${config.preset.github-ci.lib.getRevision "GitHub event" rev}"
      else "."
    );
in {
  last = {...}: {
    imports = [common];

    config = {
      after = ["build"];

      command.text = ''
        echo "Testing followup step"
        nix develop -L -c hello
        echo
        echo "Done..."
      '';

      preset.github-ci.clone = true;

      memory = 1024 * 2;
      nomad.resources.cpu = 1000;
    };
  };

  build = args: {
    imports = [common];

    config = {
      command.text = "nix build -L ${flakeUrl args}";

      env.NIX_CONFIG = ''
        extra-system-features = kvm
      '';

      memory = 1024 * 24;
      nomad.resources.cpu = 10000;
    };
  };
}
