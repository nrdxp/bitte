{ mkSystem, lib }:

{ self # target flake's 'self'
, inputs, pkgs, clusterFiles, hydrateModule }:

lib.listToAttrs (lib.forEach clusterFiles (file:
  let
    inherit (_proto.config) tf;

    _proto = (mkSystem {
      inherit pkgs self inputs;
      modules = [ file hydrateModule ];
    }).bitteProtoSystem;

    # Separating core and premSim nodes may cause bitte-cli tooling to break.
    # Currently groupings are viewed as core or awsAsg.
    # May be able to split premSim nodes out going forward.
    coreAndPremSimNodes = assert (lib.assertMsg (!builtins.any
      (e: builtins.elem e (builtins.attrNames _proto.config.cluster.coreNodes))
      (builtins.attrNames _proto.config.cluster.premSimNodes)) ''
        ERROR
        trace: ERROR  -->  premSimNodes may not have the same names as coreNodes
      '');
      _proto.config.cluster.premSimNodes // _proto.config.cluster.coreNodes;

    coreNodes = lib.mapAttrs (nodeName: coreNode:
      (mkSystem {
        inherit pkgs self inputs nodeName;
        modules = [ { networking.hostName = lib.mkForce nodeName; } file hydrateModule ]
          ++ coreNode.modules;
      }).bitteAmazonSystem) coreAndPremSimNodes;

    awsAutoScalingGroups = lib.mapAttrs (nodeName: awsAutoScalingGroup:
      (mkSystem {
        inherit pkgs self inputs nodeName;
        modules = [ file ] ++ awsAutoScalingGroup.modules;
      }).bitteAmazonZfsSystem) _proto.config.cluster.awsAutoScalingGroups;

  in lib.nameValuePair _proto.config.cluster.name {
    inherit _proto tf coreNodes awsAutoScalingGroups;
  }))
