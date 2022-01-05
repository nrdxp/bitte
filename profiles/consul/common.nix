{ lib, pkgs, config, nodeName, pkiFiles, ... }: let

  Imports = { imports = [ ./common.nix ]; };

  Switches = {
    services.consul.enable = true;
    services.consul.consul.enable = true;
    services.dnsmasq.enable = true;
  };

  Config = let ownedKey = "/var/lib/consul/cert-key.pem";
  in {
    services.consul = {
      addresses = { http = lib.mkDefault "127.0.0.1"; };

      clientAddr = "0.0.0.0";
      datacenter = config.cluster.region;
      enableLocalScriptChecks = true;
      logLevel = "info";
      primaryDatacenter = config.cluster.region;
      tlsMinVersion = "tls12";
      verifyIncoming = true;
      verifyOutgoing = true;
      verifyServerHostname = true;

      caFile = pkiFiles.caCertFile;
      certFile = pkiFiles.certChainFile;
      keyFile = ownedKey;

      telemetry = {
        dogstatsdAddr = "localhost:8125";
        disableHostname = true;
      };

      nodeMeta = {
        inherit (config.cluster) region;
        inherit nodeName;
      } // (lib.optionalAttrs ((config.currentCoreNode or null) != null) {
        inherit (config.currentCoreNode) instanceType domain;
      });

      # generate deterministic UUIDs for each node so they can rejoin.
      nodeId = lib.mkIf (config.currentCoreNode != null) (lib.fileContents
        (pkgs.runCommand "node-id" { buildInputs = [ pkgs.utillinux ]; }
          "uuidgen -s -n ab8c189c-e764-4103-a1a8-d355b7f2c814 -N ${nodeName} > $out"));

      bindAddr = ''{{ GetInterfaceIP "ens5" }}'';

      advertiseAddr = ''{{ GetInterfaceIP "ens5" }}'';

      retryJoin = (lib.mapAttrsToList (_: v: v.privateIP) config.cluster.coreNodes)
        ++ [ "provider=aws region=${config.cluster.region} tag_key=Consul tag_value=server" ];

      connect = {
        caProvider = "consul";
      };

      ports = {
        grpc = 8502;
        https = 8501;
        http = 8500;
      };
    };

    services.dnsmasq = {
      extraConfig = ''
        # Ensure docker0 is also bound on client machines when it may not exist during dnsmasq startup:
        # - This ensures nomad docker driver jobs have dnsmasq access
        # - This enables nomad exec driver bridge mode jobs to use the docker bridge for dnsmasq access
        #   when explicitly defined as a nomad network dns server ip
        bind-dynamic

        # Redirect consul and ec2 internal specific queries to their respective upstream DNS servers
        server=/consul/127.0.0.1#8600
        server=/internal/169.254.169.253#53

        # Configure reverse in-addr.arpa DNS lookups to consul for ASGs and core datacenter default address ranges
        rev-server=10.0.0.0/8,127.0.0.1#8600
        rev-server=172.16.0.0/16,127.0.0.1#8600

        # Define upstream DNS servers
        server=169.254.169.253
        server=8.8.8.8

        # Set cache and security
        cache-size=65536
        local-service
      '';
    };

    # Restarts automatically upon fail, ex: memory limit hit
    systemd.services.dnsmasq.startLimitIntervalSec = 0;
    systemd.services.dnsmasq.serviceConfig.RestartSec = "1s";
    systemd.services.dnsmasq.serviceConfig.MemoryMax = "128M";

    # Used for Consul Connect and requires reboot?
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-arptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
    };
  };

in lib.mkMerge [
  Imports
  Switches
  Config
]