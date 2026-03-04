#!/usr/bin/env bash

set -ueEo pipefail

export PATH=~/.local/bin:$PATH

E2E_DIR="$(dirname -- "${BASH_SOURCE[0]}")"

cd "$E2E_DIR"
git clean -dxf

# https://opentofu.org/docs/cli/config/config-file/#locations
export TF_CLI_CONFIG_FILE=$PWD/test.tfrc
# https://opentofu.org/docs/cli/config/config-file/#development-overrides-for-provider-developers
cat >"$TF_CLI_CONFIG_FILE" <<EOF
provider_installation {
  dev_overrides {
    "7learnings/stacks-lite" = "$PWD/../../"
  }

  direct {}
}
EOF

# test planning through both stacks
cd upstream/
tofu init
tofu plan -out=tfplan
tofu show -json tfplan >tfplan.json
cd ../downstream
# no init with dev_overrides
tofu refresh
tofu plan -out=tfplan
tofu show -json tfplan >tfplan.json

test "$(jq -r .output_changes.known.after tfplan.json)" == 'this is a known value'
test "$(jq -r .output_changes.random.after_unknown tfplan.json)" == 'true'

cd ../upstream
# this requires opentofu 1.12 / alternative hit the remote state with tofu output -json
tofu apply -json-into=apply.log.json tfplan
tail -n 1 apply.log.json | jq .outputs | sponge outputs.json
cd ../downstream
tofu apply tfplan
tofu refresh

# test planning with provider config instead
unset STACKS_ROOT
cat >provider.tf <<EOF
provider "stacks" {
  stacks_root = ".."
}
EOF
tofu plan

# test planning from state without upstream plan
git clean -dxf ../upstream
tofu refresh
tofu plan -out=tfplan
tofu apply tfplan
tofu refresh
rm provider.tf
