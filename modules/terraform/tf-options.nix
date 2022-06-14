{
  _protoConfig,
  pkgs,
  lib,
  config,
  name,
  terranix,
  ...
}: let
  cfg = _protoConfig.cluster;
  isPrem = cfg.infraType == "prem";
  tfBranch = "tf";

  # encryptedRoot attrs must be declared at the config.* _proto level in the ops/world repos to be accessible here
  relEncryptedFolder = let
    extract = path: lib.last (builtins.split "/nix/store/.{32}-" (toString path));
  in
    if isPrem
    then extract _protoConfig.age.encryptedRoot
    else extract _protoConfig.secrets.encryptedRoot;

  sopsDecrypt = inputType: path:
  # NB: we can't work on store paths that don't yet exist before they are generated
    assert lib.assertMsg (builtins.isString path) "sopsDecrypt: path must be a string ${toString path}"; "sops --decrypt --input-type ${inputType} ${path}";

  sopsEncrypt = inputType: outputType: path:
    assert lib.assertMsg (builtins.isString path) "sopsDecrypt: path must be a string ${toString path}"; "sops --encrypt --kms ${toString cfg.kms} --input-type ${inputType} --output-type ${outputType} ${path}";

  backend = "${cfg.vaultBackend}/v1";

  coreNode =
    if isPrem
    then "${cfg.name}-core-1"
    else "core-1";

  coreNodeCmd =
    if isPrem
    then "ssh"
    else "${pkgs.bitte}/bin/bitte ssh";

  encState = "${relEncryptedFolder}/tf/terraform-${name}.tfstate.enc";

  exportPath = ''
    export PATH="${
      with pkgs;
        lib.makeBinPath [
          coreutils
          curl
          gitMinimal
          jq
          rage
          sops
          terraform-with-plugins
        ]
    }"
  '';

  # Generate declarative TF configuration and copy it to the top level repo dir
  copyTfCfg = ''
    set -euo pipefail
    ${exportPath}

    rm -f config.tf.json
    cp "${config.output}" config.tf.json
    chmod u+rw config.tf.json
  '';

  # Encrypt local state to the encrypted folder.
  # Use binary encryption instead of json for more compact representation
  # and to reduce information leakage via many unencrypted json keys.
  localStateEncrypt = ''
    if [ "${cfg.vbkBackend}" = "local" ]; then
      # Only encrypt and git add state if the sha256sums are different indicating a state change
      STATE_SHA256_POST="$(sha256sum terraform-${name}.tfstate)"

      if [ "''${STATE_SHA256_PRE%% *}" != "''${STATE_SHA256_POST%% *}" ]; then
        echo "Encrypting TF state changes to: ${encState}"
        if [ "${cfg.infraType}" = "prem" ]; then
          rage -i secrets-prem/age-bootstrap -a -e "terraform-${name}.tfstate" > "${encState}"
        else
          ${sopsEncrypt "binary" "binary" "terraform-${name}.tfstate"} > "${encState}"
        fi

        echo "Git adding state changes"
        git add ${if name == "hydrate-secrets" then "-f" else ""} "${encState}"

        echo
        warn "Please commit these TF state changes ASAP to avoid loss of state or state divergence!"
      fi
    fi
  '';

  # Local plaintext state should be uncommitted and cleaned up routinely
  # as some workspaces contain secrets, ex: hydrate-app
  localStateCleanup = ''
    if [ "${cfg.vbkBackend}" = "local" ]; then
      echo
      echo "Removing plaintext TF state files in the repo top level directory"
      echo "(alternatively, see the encrypted-committed TF state files as needed)"
      rm -vf terraform-${name}.tfstate
      rm -vf terraform-${name}.tfstate.backup
    fi
  '';

  migStartStatus = ''
    echo
    echo "Important environment variables"
    echo "  config.cluster.name              = ${cfg.name}"
    echo "  BITTE_CLUSTER env parameter      = $BITTE_CLUSTER"
    echo
    echo "Important migration variables:"
    echo "  infraType                        = ${cfg.infraType}"
    echo "  vaultBackend                     = ${cfg.vaultBackend}"
    echo "  vbkBackend                       = ${cfg.vbkBackend}"
    echo "  vbkBackendSkipCertVerification   = ${lib.boolToString cfg.vbkBackendSkipCertVerification}"
    echo "  script STATE_ARG                 = ''${STATE_ARG:-remote}"
    echo "  tfBranch                         = ${tfBranch}"
    echo
    echo "Important path variables:"
    echo "  gitTopLevelDir                   = $TOP"
    echo "  currentWorkingDir                = $PWD"
    echo "  relEncryptedFolder               = ${relEncryptedFolder}"
    echo
  '';

  migCommonChecks = ''
    warn "PRE-MIGRATION CHECKS:"
    echo
    echo "Status:"

    # Ensure the TF workspace is available for the given infraType
    STATUS="$([ "${cfg.infraType}" = "prem" ] && [[ "${name}" =~ ^core$|^clients$|^prem-sim$ ]] && echo "FAIL" || echo "pass")"
    echo "  Infra type workspace check:      = $STATUS"
    gate "$STATUS" "The cluster infraType of \"prem\" cannot use the \"${name}\" TF workspace."

    # Ensure there is nothing strange with environment and cluster name mismatch that may cause unexpected issues
    STATUS="$([ "${cfg.name}" = "$BITTE_CLUSTER" ] && echo "pass" || echo "FAIL")"
    echo "  Cluster name check:              = $STATUS"
    gate "$STATUS" "The nix configured name of the cluster does not match the BITTE_CLUSTER env var."

    # Ensure the migration is being run from the top level of the git repo
    STATUS="$([ "$PWD" = "$TOP" ] && echo "pass" || echo "FAIL")"
    echo "  Current pwd check:               = $STATUS"
    gate "$STATUS" "The vbk migration to local state needs to be run from the top level dir of the git repo."

    # Ensure terraform config for workspace ${name} exists and has file size greater than zero bytes
    STATUS="$([ -s "config.tf.json" ] && echo "pass" || echo "FAIL")"
    echo "  Terraform config check:          = $STATUS"
    gate "$STATUS" "The terraform config.tf.json file for workspace ${name} does not exist or is zero bytes in size."

    # Ensure terraform config for workspace ${name} has expected remote backend state set properly
    STATUS="$([ "$(jq -e -r .terraform.backend.http.address < config.tf.json)" = "${cfg.vbkBackend}/state/${cfg.name}/${name}" ] && echo "pass" || echo "FAIL")"
    echo "  Terraform remote address check:  = $STATUS"
    gate "$STATUS" "The TF generated remote address does not match the expected declarative address."
  '';

  prepare = ''
    # shellcheck disable=SC2050
    set -euo pipefail
    ${exportPath}

    warn () {
      # Star header len matching the input str len
      printf '*%.0s' $(seq 1 ''${#1})

      echo -e "\n$1"

      # Star footer len matching the input str len
      printf '*%.0s' $(seq 1 ''${#1})
      echo
    }

    gate () {
      [ "$1" = "pass" ] || { echo; echo -e "FAIL: $2"; exit 1; }
    }

    TOP="$(git rev-parse --show-toplevel)"
    PWD="$(pwd)"

    # Ensure this TF operation is being run from the top level of the git repo
    STATUS="$([ "$PWD" = "$TOP" ] && echo "pass" || echo "FAIL")"
    MSG=(
      "The TF attrs need to be run from the top level directory of the repo:\n"
      " * Top level repo directory is:\n"
      "   $TOP\n\n"
      " * Current working directory is:\n"
      "   $PWD"
    )
    # shellcheck disable=SC2116
    gate "$STATUS" "$(echo "''${MSG[@]}")"

    if [ "${name}" = "hydrate-cluster" ]; then
      if [ "${cfg.infraType}" = "prem" ]; then
        NOMAD_TOKEN="$(rage -i secrets-prem/age-bootstrap -d "${relEncryptedFolder}/nomad/nomad.bootstrap.enc.json" | jq -r '.token')"
        VAULT_TOKEN="$(rage -i secrets-prem/age-bootstrap -d "${relEncryptedFolder}/vault/vault.enc.json" | jq -r '.root_token')"
        CONSUL_HTTP_TOKEN="$(rage -i secrets-prem/age-bootstrap -d "${relEncryptedFolder}/consul/token-master.age")"
      else
        NOMAD_TOKEN="$(${sopsDecrypt "json" "${relEncryptedFolder}/nomad.bootstrap.enc.json"} | jq -r '.token')"
        VAULT_TOKEN="$(${sopsDecrypt "json" "${relEncryptedFolder}/vault.enc.json"} | jq -r '.root_token')"
        CONSUL_HTTP_TOKEN="$(${sopsDecrypt "json" "${relEncryptedFolder}/consul-core.json"} | jq -r '.acl.tokens.master')"
      fi

      export NOMAD_TOKEN
      export VAULT_TOKEN
      export CONSUL_HTTP_TOKEN
    fi

    for arg in "$@"
    do
      case "$arg" in
        *routing*)
          echo
          echo -----------------------------------------------------
          echo CAUTION: It appears that you are indulging on a
          echo terraform operation specifically involving routing.
          echo Are you redeploying routing?
          echo -----------------------------------------------------
          echo You MUST know that a redeploy of routing will
          echo necesarily re-trigger the bootstrapping of the ACME
          echo service.
          echo -----------------------------------------------------
          echo You MUST also know that LetsEncrypt enforces a non-
          echo recoverable rate limit of 5 generations per week.
          echo That means: only ever redeploy routing max 5 times
          echo per week on a rolling basis. Switch to the LetsEncrypt
          echo staging envirenment if you plan on deploying routing
          echo more often!
          echo -----------------------------------------------------
          echo
          read -p "Do you want to continue this operation? [y/n] " -n 1 -r
          echo
          [[ ! "$REPLY" =~ ^[Yy]$ ]] && exit 0
          ;;
      esac
    done

    # Generate and copy declarative TF state locally for TF to compare to
    ${copyTfCfg}

    if [ "${cfg.vbkBackend}" != "local" ]; then
      if [ -z "''${GITHUB_TOKEN:-}" ]; then
        echo
        echo -----------------------------------------------------
        echo ERROR: env variable GITHUB_TOKEN is not set or empty.
        echo Yet, it is required to authenticate before the
        echo utilizing the cluster vault terraform backend.
        echo -----------------------------------------------------
        echo "Please 'export GITHUB_TOKEN=ghp_hhhhhhhh...' using"
        echo your appropriate personal github access token.
        echo -----------------------------------------------------
        exit 1
      fi

      user="''${TF_HTTP_USERNAME:-TOKEN}"
      pass="''${TF_HTTP_PASSWORD:-$( \
        curl -s -d "{\"token\": \"$GITHUB_TOKEN\"}" \
        ${backend}/auth/github-terraform/login \
        | jq -r '.auth.client_token' \
      )}"

      if [ -z "''${TF_HTTP_PASSWORD:-}" ]; then
        echo
        echo -----------------------------------------------------
        echo TIP: you can avoid repetitive calls to the infra auth
        echo api by exporting the following env variables as is.
        echo
        echo The current vault backend in use for TF is:
        echo ${cfg.vaultBackend}
        echo -----------------------------------------------------
        echo "export TF_HTTP_USERNAME=\"$user\""
        echo "export TF_HTTP_PASSWORD=\"$pass\""
        echo -----------------------------------------------------
      fi

      export TF_HTTP_USERNAME="$user"
      export TF_HTTP_PASSWORD="$pass"

      echo "Using remote TF state for workspace \"${name}\"..."
      terraform init -reconfigure 1>&2
      STATE_ARG=""
    else
      echo "Using local TF state for workspace \"${name}\"..."

      # Ensure that local terraform state for workspace ${name} exists
      # Pull all remote updates as we don't know yet which remote we might be using; it might not be origin
      # The time for updating all remote branches seems about the same as updating a single remote branch
      git remote update

      # Get the current branch and remote via: $BRANCH/$ORIGIN
      # shellcheck disable=SC1083
      CMD="$(git rev-parse --abbrev-ref @{upstream})"

      # Set git variables used only when vbkBackend is "local"
      # shellcheck disable=SC2034
      BRANCH="''${CMD##*/}"
      # shellcheck disable=SC2034
      ORIGIN="''${CMD%%/*}"

      # Assume we DO want to use the tfBranch on the same remote as the current branch
      # shellcheck disable=SC2034
      ENC_STATE_REF="''${ORIGIN}/${tfBranch}:${encState}"

      # Assume the tfBranch is only used for storing TF state and nothing else
      STATUS="$([ "$BRANCH" != "${tfBranch}" ] && echo "pass" || echo "FAIL")"
      gate "$STATUS" "Terraform local state is stored exclusively in branch ${tfBranch}.  Please switch to another working branch."

      STATUS="$(git cat-file -e "$ENC_STATE_REF" &> /dev/null && echo "pass" || echo "FAIL")"
      MSG=(
        "The nix _proto level cluster.vbkBackend option is set to \"local\", however\n"
        " terraform local state for workspace \"${name}\" does not exist at:\n\n"
        "   $ENC_STATE_REF\n\n"
        "If all TF workspaces are not yet migrated to local, then:\n"
        " * Set the cluster.vbkBackend option back to the existing remote backend\n"
        " * Run the following against each TF workspace that is not yet migrated to local state:\n"
        "   nix run .#clusters.$BITTE_CLUSTER.tf.<TF_WORKSPACE>.migrateLocal\n"
        " * Finally, set the cluster.vbkBackend option to \"local\""
      )
      # shellcheck disable=SC2116
      gate "$STATUS" "$(echo "''${MSG[@]}")"

      # Ensure there is no unknown terraform state in the current directory
      for STATE in terraform*.tfstate terraform*.tfstate.backup; do
        [ -f "$STATE" ] && {
          echo
          echo "Leftover terraform local state exists in the top level repo directory at:"
          echo "  ''${TOP}/$STATE"
          echo
          echo "This may be due to a failed terraform command."
          echo "Diff may be used to compare leftover state against encrypted-committed state."
          echo
          echo "When all expected state is confirmed to reside in the encrypted-committed state,"
          echo "then delete this $STATE file and try again."
          echo
          echo "A diff example command for sops encrypted-commited state is:"
          echo
          echo "  icdiff $STATE \\"
          if [ "${cfg.infraType}" = "prem" ]; then
            echo "  <(git cat-file blob \"$ENC_STATE_REF\" | rage -i secrets-prem/age-bootstrap -d)"
          else
            echo "  <(git cat-file blob \"$ENC_STATE_REF\" | sops -d /dev/stdin)"
          fi
          echo
          echo "Leftover plaintext TF state should not be committed and should be removed as"
          echo "soon as possible since it may contain secrets."
          exit 1
        }
      done

      # UNEEDED?
      #  * If we can't be in tfBranch, then there can't be uncommitted changes here
      #  * If tfBranch doesn't have any code other than TF state, then even if it's checked out somewhere,
      #    it's unlikely to have uncommitted changes
      #
      # Check if uncommitted changes to local state already exist
      # [ -z "$(git status --porcelain=2 "${encState}")" ] || {
      #   echo
      #   warn "WARNING: Uncommitted TF state changes already exist for workspace \"${name}\" at encrypted file:"
      #   echo
      #   echo "  ${encState}"
      #   echo
      #   echo "This script will not keep any TF made state plaintext backup files since changes to"
      #   echo "local state are intended to be encrypted and committed to VCS immediately after being made."
      #   echo "This practice serves as both a TF history and backup set."
      #   echo
      #   echo "However, uncommitted TF state changes are detected.  By running this command,"
      #   echo "any new changes to TF state will be automatically git added to these existing uncomitted changes."
      #   read -p "Do you want to continue this operation? [y/n] " -n 1 -r
      #   echo
      #   [[ ! "$REPLY" =~ ^[Yy]$ ]] && exit 0
      # }

      # Removing existing .terraform/terraform.tfstate avoids a backend reconfigure failure
      # or a remote state migration pull which has already been done via the migrateLocal attr.
      #
      # Our deployments do not currently store anything but backend
      # or local state information in this hidden directory tfstate file.
      #
      # Ref: https://stackoverflow.com/questions/70636974/side-effects-of-removing-terraform-folder
      rm -vf .terraform/terraform.tfstate
      if [ "${cfg.infraType}" = "prem" ]; then
        git cat-file blob "$ENC_STATE_REF" \
        | rage -i secrets-prem/age-bootstrap -d > terraform-${name}.tfstate
      else
        git cat-file blob "$ENC_STATE_REF" \
        | ${sopsDecrypt "binary" "/dev/stdin"} > terraform-${name}.tfstate
      fi

      terraform init -reconfigure 1>&2
      STATE_ARG="-state=terraform-${name}.tfstate"
      # shellcheck disable=SC2034
      STATE_SHA256_PRE="$(sha256sum terraform-${name}.tfstate)"
    fi
  '';
in {
  options = {
    configuration = lib.mkOption {
      type = with lib.types;
        submodule {
          imports = [(terranix + "/core/terraform-options.nix")];
        };
    };

    output = lib.mkOption {
      type = lib.mkOptionType {name = "${name}_config.tf.json";};
      apply = v:
        terranix.lib.terranixConfiguration {
          inherit pkgs;
          modules = [config.configuration];
          strip_nulls = false;
        };
    };

    config = lib.mkOption {
      type = lib.mkOptionType {name = "${name}-config";};
      apply = v: pkgs.writeBashBinChecked "${name}-config" copyTfCfg;
    };

    plan = lib.mkOption {
      type = lib.mkOptionType {name = "${name}-plan";};
      apply = v:
        pkgs.writeBashBinChecked "${name}-plan" ''
          ${prepare}

          terraform plan ''${STATE_ARG:-} -out ${name}.plan "$@"
          ${localStateCleanup}
        '';
    };

    apply = lib.mkOption {
      type = lib.mkOptionType {name = "${name}-apply";};
      apply = v:
        pkgs.writeBashBinChecked "${name}-apply" ''
          ${prepare}

          terraform apply ''${STATE_ARG:-} ${name}.plan "$@"
          ${localStateEncrypt}
          ${localStateCleanup}
        '';
    };

    terraform = lib.mkOption {
      type = lib.mkOptionType {name = "${name}-custom";};
      apply = v:
        pkgs.writeBashBinChecked "${name}-custom" ''
          ${prepare}

          [ "${cfg.vbkBackend}" = "local" ] && {
            warn "Nix custom terraform command usage note for local state:"
            echo
            echo "Depending on the terraform command you are running,"
            echo "the state file argument may need to be provided:"
            echo
            echo "  $STATE_ARG"
            echo
            echo "********************************************************"
            echo
          }

          terraform "$@"
          ${localStateEncrypt}
          ${localStateCleanup}
        '';
    };

    migrateLocal = lib.mkOption {
      type = lib.mkOptionType {name = "${name}-migrateLocal";};
      apply = v:
        pkgs.writeBashBinChecked "${name}-migrateLocal" ''
          ${prepare}

          warn "TERRAFORM VBK MIGRATION TO *** LOCAL STATE *** FOR ${name}:"

          ${migStartStatus}
          ${migCommonChecks}

          # Ensure the vbk status is not already local
          STATUS="$([ "${cfg.vbkBackend}" != "local" ] && echo "pass" || echo "FAIL")"
          echo "  Terraform backend check:         = $STATUS"
          MSG=(
            "The nix _proto level cluster.vbkBackend option is already set to \"local\".\n"
            "If all TF workspaces are not yet migrated to local, then:\n"
            " * Set the cluster.vbkBackend option back to the existing remote backend\n"
            " * Run the following against each TF workspace that is not yet migrated to local state:\n"
            "   nix run .#clusters.$BITTE_CLUSTER.tf.<TF_WORKSPACE>.migrateLocal\n\n"
            " * Finally, set the cluster.vbkBackend option to \"local\"\n"
          )
          # shellcheck disable=SC2116
          gate "$STATUS" "$(echo "''${MSG[@]}")"

          # UPDATE
          # Ensure that local terraform state for workspace ${name} does not already exist
          STATUS="$([ ! -f "${encState}" ] && echo "pass" || echo "FAIL")"
          echo "  Terraform local state presence:  = $STATUS"
          gate "$STATUS" "Terraform local state for workspace \"${name}\" appears to already exist at: ${encState}"
          echo

          warn "STARTING MIGRATION FOR TF WORKSPACE ${name}"
          echo
          echo "Status:"

          # UPDATE
          # Ensure the target state encrypted directory path exists
          echo -n "  Creating target state path       "
          mkdir -p "${relEncryptedFolder}/tf"
          echo "...done"

          # Set up a tmp work dir
          echo -n "  Create a tmp work dir            "
          TMPDIR="$(mktemp -d -t tf-${name}-migrate-local-XXXXXX)"
          trap 'rm -rf -- "$TMPDIR"' EXIT
          echo "...done"

          # Pull remote state for ${name} to the tmp work dir
          echo -n "  Fetching remote state            "
          terraform state pull > "$TMPDIR/terraform-${name}.tfstate"
          echo "...done"

          # Encrypt the plaintext TF state file
          echo -n "  Encrypting locally               "
          if [ "${cfg.infraType}" = "prem" ]; then
            rage -i secrets-prem/age-bootstrap -a -e "$TMPDIR/terraform-${name}.tfstate" > "${encState}"
          else
            ${sopsEncrypt "binary" "binary" "\"$TMPDIR/terraform-${name}.tfstate\""} > "${encState}"
          fi
          echo "...done"
          echo

          # Git add encrypted state
          # In the case of hydrate-secrets, force add to avoid git exclusion in some ops/world repos based on the filename containing the word secret
          echo -n "  Adding encrypted state to git    "
          git add ${if name == "hydrate-secrets" then "-f" else ""} "${encState}"
          echo "...done"
          echo

          # UPDATE
          warn "FINISHED MIGRATION TO LOCAL FOR TF WORKSPACE ${name}"
          echo
          echo "  * The encrypted local state file is found at:"
          echo "    ${encState}"
          echo
          echo "  * Decrypt and review with:"
          if [ "${cfg.infraType}" = "prem" ]; then
            echo "    rage -i secrets-prem/age-bootstrap -d \"${encState}\""
          else
            echo "    sops -d \"${encState}\""
            echo
            echo "NOTE: binary sops encryption is used on the TF state files both for more compact representation"
            echo "      and to avoid unencrypted keys from contributing to an information attack vector."
          fi
          echo
          echo "  * Once the local state is confirmed working as expected, the corresponding remote state no longer in use may be deleted:"
          echo "    ${cfg.vbkBackend}/state/${cfg.name}/${name}"
          echo
        '';
    };

    migrateRemote = lib.mkOption {
      type = lib.mkOptionType {name = "${name}-migrateRemote";};
      apply = v:
        pkgs.writeBashBinChecked "${name}-migrateRemote" ''
          ${prepare}

          warn "TERRAFORM VBK MIGRATION TO *** REMOTE STATE *** FOR ${name}:"

          ${migStartStatus}
          ${migCommonChecks}

          # Ensure the vbk status is already remote as the target vbkBackend remote parameter is required
          STATUS="$([ "${cfg.vbkBackend}" != "local" ] && echo "pass" || echo "FAIL")"
          echo "  Terraform backend check:         = $STATUS"
          MSG=(
            "The nix _proto level cluster.vbkBackend option is already set to \"local\".\n"
            "If all TF workspaces are not yet migrated to remote, then:\n"
            " * Set the cluster.vbkBackend option to the target migration remote backend, example:\n"
            "   https://vbk.\$FQDN\n\n"
            " * Run the following against each TF workspace that is not yet migrated to remote state:\n"
            "   nix run .#clusters.$BITTE_CLUSTER.tf.<TF_WORKSPACE>.migrateRemote\n\n"
            " * Remove the TF local state which is no longer in use at your convienence"
          )
          # shellcheck disable=SC2116
          gate "$STATUS" "$(echo "''${MSG[@]}")"

          # Ensure that local terraform state for workspace ${name} does already exist
          STATUS="$([ -f "${encState}" ] && echo "pass" || echo "FAIL")"
          echo "  Terraform local state presence:  = $STATUS"
          gate "$STATUS" "Terraform local state for workspace \"${name}\" appears to not already exist at: ${encState}"

          # Ensure that remote terraform state for workspace ${name} does not already exist
          STATUS="$(terraform state list &> /dev/null && echo "FAIL" || echo "pass")"
          echo "  Terraform remote state presence: = $STATUS"
          MSG=(
            "Terraform remote state for workspace \"${name}\" appears to already exist at backend vbk path: ${cfg.vbkBackend}/state/${cfg.name}/${name}\n"
            " * Pushing local TF state to remote will reset the lineage and serial number of the remote state by default\n"
            " * If this local state still needs to be pushed to this remote:\n"
            "   * Ensure remote state is not needed\n"
            "   * Back it up if desired\n"
            "   * Clear this particular vbk remote state path key\n"
            "   * Try again\n"
            " * This will ensure lineage conflicts, serial state conflicts, and otherwise unexpected state data loss are not encountered"
          )
          # shellcheck disable=SC2116
          gate "$STATUS" "$(echo "''${MSG[@]}")"
          echo

          warn "STARTING MIGRATION FOR TF WORKSPACE ${name}"
          echo
          echo "Status:"

          # Set up a tmp work dir
          echo -n "  Create a tmp work dir            "
          TMPDIR="$(mktemp -d -t tf-${name}-migrate-remote-XXXXXX)"
          trap 'rm -rf -- "$TMPDIR"' EXIT
          echo "...done"

          # Decrypt the pre-existing TF state file
          echo -n "  Decrypting locally               "
          if [ "${cfg.infraType}" = "prem" ]; then
            rage -i secrets-prem/age-bootstrap -d "${encState}" > "$TMPDIR/terraform-${name}.tfstate"
          else
            ${sopsDecrypt "binary" "${encState}"} > "$TMPDIR/terraform-${name}.tfstate"
          fi
          echo "...done"
          echo

          # Copy the config with generated remote
          echo -n "  Setting up config.tf.json        "
          cp config.tf.json "$TMPDIR/config.tf.json"
          echo "...done"
          echo

          # Initialize a new TF state dir with remote backend
          echo "  Initializing remote config       "
          echo
          pushd "$TMPDIR"
          terraform init -reconfigure
          echo "...done"
          echo

          # Push the local state to the remote
          echo "  Pushing local state to remote    "
          echo
          terraform state push terraform-${name}.tfstate
          echo "...done"
          echo
          popd
          echo

          warn "FINISHED MIGRATION TO REMOTE FOR TF WORKSPACE ${name}"
          echo
          echo "  * The new remote state file is found at vbk path:"
          echo "    ${cfg.vbkBackend}/state/${cfg.name}/${name}"
          echo
          echo "  * The associated encrypted local state no longer in use may now be deleted:"
          echo "    ${encState}"
          echo
        '';
    };
  };
}
