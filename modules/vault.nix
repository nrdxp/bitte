{
  lib,
  config,
  pkgs,
  nodeName,
  bittelib,
  hashiTokens,
  gossipEncryptionMaterial,
  pkiFiles,
  ...
}: let
  deployType = config.currentCoreNode.deployType or config.currentAwsAutoScalingGroup.deployType;
  sanitize = obj:
    lib.getAttr (builtins.typeOf obj) {
      bool = obj;
      int = obj;
      string = obj;
      str = obj;
      list = map sanitize obj;
      inherit null;
      set =
        if (builtins.length (builtins.attrNames obj) == 0)
        then null
        else
          lib.pipe obj [
            (lib.filterAttrs
              (name: value: name != "_module" && name != "_ref" && value != null))
            (lib.mapAttrs' (name: value:
                lib.nameValuePair (bittelib.snakeCase name) (sanitize value)))
          ];
    };

  storageRaftType = with lib.types;
    submodule {
      options = {
        path = lib.mkOption {
          type = with lib.types; str;
          default = cfg.storagePath;
        };

        nodeId = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
        };

        retryJoin = lib.mkOption {
          type = with lib.types;
            listOf (submodule {
              options = {
                leaderApiAddr = lib.mkOption {
                  type = with lib.types; str;
                  description = ''
                    Address of a possible leader node.
                  '';
                };

                leaderCaCertFile = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = ''
                    File path to the CA cert of the possible leader node.
                  '';
                };

                leaderCaCert = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = ''
                    CA cert of the possible leader node.
                  '';
                };

                leaderClientCertFile = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = ''
                    File path to the client certificate for the follower
                    node to establish client authentication with the
                    possible leader node.
                  '';
                };

                leaderClientCert = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = ''
                    Client certificate for the follower node to establish
                    client authentication with the possible leader node.
                  '';
                };

                leaderClientKeyFile = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = ''
                    File path to the client key for the follower node to
                    establish client authentication with the possible
                    leader node.
                  '';
                };

                leaderClientKey = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = ''
                    Client key for the follower node to establish client
                    authentication with the possible leader node.
                  '';
                };
              };
            });
          default = [];
        };
      };
    };

  cfg = config.services.vault;
in {
  disabledModules = ["services/security/vault.nix"];
  options.services.vault = {
    enable = lib.mkEnableOption "Vault daemon";

    storagePath = lib.mkOption {
      type = with lib.types; str;
      default = "/var/lib/vault";
    };

    configDir = lib.mkOption {
      type = with lib.types; str;
      default = "vault.d";
    };

    serverNodeNames = lib.mkOption {
      type = with lib.types; listOf str;
      default =
        if deployType != "premSim"
        then ["core-1" "core-2" "core-3"]
        else ["prem-1" "prem-2" "prem-3"];
    };

    serverNameAddressing = lib.mkOption {
      type = with lib.types; bool;
      default = false;
      description = ''
        By default, vault server IPs will be used to specify raft peers, api and cluster addresses.
        With vault server TLS requirements, the vault server IPs must then be embedded in the cert files.
        This may force unwanted cert rotation in the case that vault servers change IPs.

        Alternatively, enabling this option will instead utilize the server hostname appended with `.internal`,
        resolved by hosts file.  Typically this will resolve in core node resolution by hostname via:
          core-1.internal
          core-2.internal
          core-3.internal
          ...

        The vault server certificate will need to have `core-$n.internal` names added to the cert SAN list.
      '';
    };

    extraConfig = lib.mkOption {
      type = with lib.types; attrs;
      default = {};
    };

    ui = lib.mkEnableOption "Enable web UI";

    logLevel = lib.mkOption {
      type = with lib.types; enum ["trace" "debug" "info" "warn" "err"];
      default = "info";
    };

    disableMlock = lib.mkEnableOption "Disable mlock";

    apiAddr = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
    };

    clusterAddr = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
    };

    storage = lib.mkOption {
      default = null;
      type = with lib.types;
        nullOr (submodule {
          options = {
            raft = lib.mkOption {
              type = with lib.types; nullOr storageRaftType;
              default = null;
            };
          };
        });
    };

    listener = lib.mkOption {
      type = with lib.types;
        submodule {
          options = {
            tcp = lib.mkOption {
              type = with lib.types;
                submodule {
                  options = {
                    address = lib.mkOption {
                      type = with lib.types; str;
                      default = "";
                    };

                    clusterAddress = lib.mkOption {
                      type = with lib.types; str;
                      default = "";
                    };

                    tlsClientCaFile = lib.mkOption {
                      type = with lib.types; str;
                      default = "";
                    };

                    tlsCertFile = lib.mkOption {
                      type = with lib.types; str;
                      default = "";
                    };

                    tlsKeyFile = lib.mkOption {
                      type = with lib.types; str;
                      default = "";
                    };

                    tlsMinVersion = lib.mkOption {
                      type = with lib.types;
                        enum ["tls10" "tls11" "tls12" "tls13"];
                      default = "tls12";
                    };
                  };
                };
              default = {};
            };
          };
        };
      default = {};
    };

    seal = lib.mkOption {
      type = with lib.types;
        nullOr (submodule {
          options = {
            awskms = lib.mkOption {
              type = with lib.types;
                nullOr (submodule {
                  options = {
                    kmsKeyId = lib.mkOption {type = with lib.types; str;};
                    region = lib.mkOption {type = with lib.types; str;};
                  };
                });
              default = null;
            };
          };
        });
      default = null;
    };

    serviceRegistration = lib.mkOption {
      type = with lib.types;
        nullOr (submodule {
          options = {
            consul = lib.mkOption {
              type = with lib.types;
                nullOr (submodule {
                  options = {
                    address = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                    };

                    scheme = lib.mkOption {
                      type = with lib.types; nullOr (enum ["http" "https"]);
                      default = null;
                    };

                    tlsClientCaFile = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                    };

                    tlsCertFile = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                    };

                    tlsKeyFile = lib.mkOption {
                      type = with lib.types; nullOr str;
                      default = null;
                    };
                  };
                });
              default = null;
            };
          };
        });
      default = null;
    };

    telemetry = lib.mkOption {
      type = with lib.types;
        submodule {
          options = {
            dogstatsdAddr = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
            };

            dogstatsdTags = lib.mkOption {
              type = with lib.types; nullOr (listOf str);
              default = null;
            };
          };
        };
    };
  };

  options.services.${hashiTokens.consul-vault-srv}.enable =
    lib.mkEnableOption "Enable Vault Consul Token";

  config = lib.mkIf cfg.enable {
    environment.etc."${cfg.configDir}/config.json".source = pkgs.toPrettyJSON "config" (sanitize {
      inherit
        (cfg)
        serviceRegistration
        ui
        logLevel
        disableMlock
        apiAddr
        clusterAddr
        seal
        listener
        storage
        telemetry
        ;
    });

    environment.etc."${cfg.configDir}/extra-config.json".source =
      pkgs.toPrettyJSON "extra-config" cfg.extraConfig;

    systemd.services.vault = {
      wantedBy = ["multi-user.target"];
      after = ["network.target"];

      restartTriggers =
        lib.mapAttrsToList (_: d: d.source)
        (lib.filterAttrs (n: _: lib.hasPrefix "${cfg.configDir}" n)
          config.environment.etc);

      unitConfig = {
        RequiresMountsFor = [cfg.storagePath];
        StartLimitInterval = "60s";
        StartLimitBurst = 3;
      };

      serviceConfig = let
        certChainFile =
          if deployType == "aws"
          then pkiFiles.certChainFile
          else pkiFiles.serverCertChainFile;
        certKeyFile =
          if deployType == "aws"
          then pkiFiles.keyFile
          else pkiFiles.serverKeyFile;
        preScript = pkgs.writeBashBinChecked "vault-start-pre" ''
          export PATH="${lib.makeBinPath [pkgs.coreutils]}"
          set -exuo pipefail
          cp ${certChainFile} full.pem
          cp ${certKeyFile} cert-key.pem
          chown --reference . --recursive .
        '';

        postScript = pkgs.writeBashBinChecked "vault-start-post" ''
          export PATH="${lib.makeBinPath [pkgs.coreutils pkgs.vault-bin]}"
          while ! vault status; do sleep 3; done
        '';
      in {
        ExecStartPre = "!${preScript}/bin/vault-start-pre";
        ExecStart = "@${pkgs.vault-bin}/bin/vault vault server -config /etc/${cfg.configDir}";

        ExecStartPost = "!${postScript}/bin/vault-start-post";
        KillSignal = "SIGINT";

        StateDirectory = baseNameOf cfg.storagePath;
        WorkingDirectory = cfg.storagePath;

        DynamicUser = true;
        User = "vault";
        Group = "vault";

        LimitMEMLOCK = "infinity";
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "full";
        ProtectHome = "read-only";
        AmbientCapabilities = "cap_ipc_lock";
        NoNewPrivileges = true;

        TimeoutStopSec = "30s";
        RestartSec = "10s";
        Restart = "on-failure";
      };
    };

    systemd.services.${hashiTokens.consul-vault-srv} = lib.mkIf config.services.${hashiTokens.consul-vault-srv}.enable {
      after = ["consul.service"];
      wantedBy = ["vault.service"];
      before = ["vault.service"];
      description = "provide a consul token for bootstrapping";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "20s";
        ExecStartPre = bittelib.ensureDependencies pkgs ["consul"];
      };

      path = with pkgs; [consul curl jq];

      script = ''
        set -exuo pipefail

        [ -s ${hashiTokens.vaultd-consul-json} ] && exit
        [ -s ${gossipEncryptionMaterial.consul} ]
        jq -e .acl.tokens.master ${gossipEncryptionMaterial.consul} || exit

        CONSUL_HTTP_TOKEN="$(jq -e -r .acl.tokens.master ${gossipEncryptionMaterial.consul})"
        export CONSUL_HTTP_TOKEN

        vaultToken="$(
          consul acl token create \
            -policy-name=vault-server \
            -description "vault-server ${nodeName} $(date +%Y-%m-%d-%H-%M-%S)" \
            -format json \
          | jq -e -r .SecretID
        )"

        echo '{}' \
        | jq --arg token "$vaultToken" '.service_registration.consul.token = $token' \
        > ${hashiTokens.vaultd-consul-json}.new

        mv ${hashiTokens.vaultd-consul-json}.new ${hashiTokens.vaultd-consul-json}
      '';
    };

    systemd.services.vault-addr = {
      wantedBy = ["vault.service"];
      before = ["vault.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "20s";
      };

      path = with pkgs; [curl jq iproute2];

      script = ''
        set -exuo pipefail

        ${
          if deployType == "aws"
          then ''
            ip="$(curl -f -s http://169.254.169.254/latest/meta-data/local-ipv4)"''
          else ''
            ip="$(ip -j addr | jq -r '.[] | select(.operstate == "UP") | .addr_info[] | select(.family == "inet") | .local')"''
        }

        addr="https://$ip"
        echo '{"cluster_addr": "'"$addr:8201"'", "api_addr": "'"$addr:8200"'"}' \
        | jq -S . \
        > /etc/vault.d/address.json
      '';
    };
  };
}
