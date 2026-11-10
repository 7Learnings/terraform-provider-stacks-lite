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

test_extra_deps_path_normalization() {
    cd example/
    local output original original_readme
    # Preserve existing edits. Unregister cleanup when it runs so it cannot leak into the runner.
    original=$(< common/tags.json)
    original_readme=$(< ../README.md)
    trap 'trap - RETURN; rm -f common/tags.json; printf "%s\n" "$original" > common/tags.json; printf "%s\n" "$original_readme" > ../README.md' RETURN

    # Use stacks.mk directly so example/Makefile adds no implicit extra dependencies.
    # Skip dependency-file generation: these assertions only exercise Git-based detection.
    local -a make_cmd=(make --no-print-directory -f ../stacks.mk
        -o .deps/dev.d ENV=dev DIFF_BASE=HEAD changed)

    # 1) A declared dependency alone must not mark any stacks changed.
    output=$("${make_cmd[@]}" EXTRA_DEPS=../example/common/./tags.json)
    assert_same '(no changed stacks detected)' "$output"

    # 2) A changed root dependency selects every stack, with or without redundant ./ and ../.
    echo '{"changed":true}' > common/tags.json
    output=$("${make_cmd[@]}" EXTRA_DEPS=common/tags.json)
    assert_same 'instances network/vpc org' "$output"
    output=$("${make_cmd[@]}" EXTRA_DEPS=../example/common/./tags.json)
    assert_same 'instances network/vpc org' "$output"

    # 3) Per-stack dependencies select only their owner, for relative and absolute paths.
    output=$("${make_cmd[@]}" EXTRA_DEPS_instances=../example/common/./tags.json)
    assert_same 'instances' "$output"
    output=$("${make_cmd[@]}" "EXTRA_DEPS_org=$PWD/common/../common/tags.json")
    assert_same 'org' "$output"

    # 4) Replace the tracked file with a symlink. Git reports common/tags.json as changed,
    #    so matching must preserve that name rather than resolve it to org/config.json.
    #    Check both per-stack and root declarations.
    rm common/tags.json
    ln -s ../org/config.json common/tags.json
    output=$("${make_cmd[@]}" EXTRA_DEPS_instances=./common/tags.json)
    assert_same 'instances' "$output"
    output=$("${make_cmd[@]}" EXTRA_DEPS=./common/tags.json)
    assert_same 'instances network/vpc org' "$output"

    # 5) A dependency genuinely outside example/ must also be detected.
    #    ../README.md lives one level up; unlike ../example/..., it does not point back inside.
    printf '\nExtra dependency regression input.\n' >> ../README.md
    output=$("${make_cmd[@]}" EXTRA_DEPS=../README.md)
    assert_same 'instances network/vpc org' "$output"
    output=$("${make_cmd[@]}" EXTRA_DEPS_instances=../README.md)
    assert_same 'instances' "$output"
}
