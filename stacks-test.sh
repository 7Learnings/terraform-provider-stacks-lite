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
    assert_contains '/network_0-all-.auto.tfvars: network/all.tfvars' "$output"
    assert_contains '/network_1-eu-.auto.tfvars: network/eu.tfvars' "$output"
    assert_contains '/network_2-dev-eu-.auto.tfvars: network/dev-eu.tfvars' "$output"
}

