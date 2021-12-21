{ config, lib, ... }: {

  imports = [ ./bootrap/default.nix ];

  services.consul-acl.enable = true;
  services.nomad-acl.enable = true;
  services.vault-acl.enable = true;
  services.nomad-namespaces.enable = true;
}
