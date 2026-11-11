#!/usr/bin/env bashunit

set_up() {
    ENV=dev-eu
    NSTACKS=0
    source stacks-gen-deps.sh $ENV $NSTACKS
}

test_branch_pattern() {
    re=$(along_branch_re path/to/dir)
    assert_string_starts_with '^(path/to/dir/|path/to/|path/|)[^/]+' $re
    assert_matches $re$ path/to/dir/leaf.tf
    assert_matches $re$ root.tf
    assert_matches $re$ path/branch.tfvars
    assert_not_matches $re$ ./root.tfvars
    assert_not_matches $re$ path/to/dir2/leaf.tf
    assert_not_matches $re$ path/to/dir/sub/below.tf
}

test_env_match() {
    ENV='dev-eu-fr'
    assert_same 3 $(env_match 'dev' $ENV)
    assert_same 2 $(env_match 'eu' $ENV)
    assert_same 1 $(env_match 'fr' $ENV)
    assert_same 3 $(env_match 'dev-eu' $ENV)
    assert_same 2 $(env_match 'eu-fr' $ENV)

    set +e
    for name in 'dev-fr' 'dev-' 'dev-e' 'eu-' 'eu-f' 'fr-'; do
        env_match "$name" "$ENV"
        assert_unsuccessful_code
    done
}

test_directory_flattening() {
    # Run the script directly to test the directory flattening logic
    cd example/
    output=$(bash ../stacks-gen-deps.sh dev-eu 1 network/vpc network/vpc/main.tf network/netplan.tf org/main.tf providers.tf network/vpc/subdir/below.tf)

    # Check that nested files in the branch are flattened correctly
    assert_contains '/network_vpc_main.tf: network/vpc/main.tf' "$output"
    assert_contains '/network_netplan.tf: network/netplan.tf' "$output"
    assert_contains '/providers.tf: providers.tf' "$output"
    assert_not_contains 'org/main.tf' "$output"
    assert_not_contains 'below' "$output"
}

test_tfvars_precedence() {
    # Run the script to test tfvars parsing and precedence mapping
    cd example/
    output=$(bash ../stacks-gen-deps.sh dev-eu 1 network/vpc network/vpc/main.tf all.tfvars dev-eu.tfvars dev.tfvars network/all.tfvars network/dev-eu.tfvars network/eu.tfvars)

    # https://opentofu.org/docs/language/values/variables/#variable-definition-precedence
    assert_contains '/0-all-.auto.tfvars: all.tfvars' "$output"
    assert_contains '/2-dev-.auto.tfvars: dev.tfvars' "$output"
    assert_contains '/2-dev-eu-.auto.tfvars: dev-eu.tfvars' "$output"
    assert_contains '/_network_0-all-.auto.tfvars: network/all.tfvars' "$output"
    assert_contains '/_network_1-eu-.auto.tfvars: network/eu.tfvars' "$output"
    assert_contains '/_network_2-dev-eu-.auto.tfvars: network/dev-eu.tfvars' "$output"
}

test_tfvars_precedence_ordering() {
    # Digit-starting, multi-layer stack: 1_network/eu.tfvars and 1_network/vpc/eu.tfvars.
    # Covers both the digit-starting regression (leading '_' sort key) and the
    # multi-layer ordering (a deeper path sorts after its parent, so it wins).
    cd example/
    output=$(bash ../stacks-gen-deps.sh dev-eu 1 1_network/vpc 1_network/vpc/main.tf all.tfvars dev-eu.tfvars dev.tfvars 1_network/all.tfvars 1_network/dev-eu.tfvars 1_network/eu.tfvars 1_network/vpc/eu.tfvars)

    # root files keep their digit prec prefix (unchanged)
    assert_contains '/0-all-.auto.tfvars: all.tfvars' "$output"
    assert_contains '/2-dev-.auto.tfvars: dev.tfvars' "$output"
    # non-root (digit-starting dir) files get the leading '_' sort key
    assert_contains '/_1_network_1-eu-.auto.tfvars: 1_network/eu.tfvars' "$output"
    assert_contains '/_1_network_vpc_1-eu-.auto.tfvars: 1_network/vpc/eu.tfvars' "$output"

    # Deeper (1_network/vpc) sorts after shallower (1_network) -> deeper wins.
    local order
    order=$(printf '%s\n' '_1_network_1-eu-.auto.tfvars' '_1_network_vpc_1-eu-.auto.tfvars' | LC_ALL=C sort)
    assert_same "$(echo "$order" | head -n1)" '_1_network_1-eu-.auto.tfvars'
    assert_same "$(echo "$order" | tail -n1)" '_1_network_vpc_1-eu-.auto.tfvars'
}

test_tfvars_precedence_tofu() {
    # End-to-end: digit-starting, multi-layer (root < 1_network < 1_network/vpc) all
    # define 'winner'. The deepest layer must win, and zzz_stacks (created by stacks.mk)
    # must sort last of all.
    cd example/
    local tmp output names n plan
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    cat > "$tmp/main.tf" <<'EOF'
terraform {
  backend "local" {}
}
variable "winner" { type = string }
output "winner" { value = var.winner }
EOF

    output=$(bash ../stacks-gen-deps.sh dev-eu 1 1_network/vpc 1_network/vpc/main.tf eu.tfvars 1_network/eu.tfvars 1_network/vpc/eu.tfvars)
    names=$(echo "$output" | grep -E '\.auto\.tfvars: ' | sed -E 's|^.*/([^/]+\.auto\.tfvars):.*$|\1|')
    while IFS= read -r n; do
        [ -n "$n" ] && echo "winner = \"$n\"" > "$tmp/$n"
    done <<< "$names"

    # Scenario A: without zzz_stacks, the deepest (_-prefixed) file must win over root
    plan=$(cd "$tmp" && tofu init -input=false -no-color >/dev/null 2>&1 && tofu plan -input=false -no-color 2>&1)
    assert_matches 'winner = "_1_network_vpc_[^"]*"' "$plan"

    # Scenario B: zzz_stacks (created by stacks.mk) must sort LAST and win
    echo 'winner = "zzz_stacks"' > "$tmp/zzz_stacks.auto.tfvars"
    plan=$(cd "$tmp" && tofu plan -input=false -no-color 2>&1)
    assert_matches 'winner = "zzz_stacks"' "$plan"
}


test_cross_stack_dependencies() {
    # Run the script to test cross-stack dependency extraction
    cd example/
    output=$(bash ../stacks-gen-deps.sh dev-eu 2 network/vpc instances network/vpc/main.tf instances/main.tf)

    # Check for downstream/upstream mapping
    assert_contains 'DOWNSTREAMS_network/vpc += instances' "$output"
    assert_contains 'UPSTREAMS_instances += network/vpc' "$output"

    # Check for plan and outputs dependencies
    assert_matches 'instances/[^/]+/tfplan.json: .*network/vpc/[^/]+/tfplan.json' "$output"
    assert_matches 'instances/[^/]+/outputs.json: .*network/vpc/[^/]+/outputs.json' "$output"

    # Check for destroy and refresh dependencies
    assert_matches 'network/vpc/[^/]+/.destroy: destroy-instances' "$output"
    assert_matches 'instances/[^/]+/.refresh: refresh-network/vpc' "$output"
}
