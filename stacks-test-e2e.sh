#!/usr/bin/env bashunit

# Run full e2e tests operating on the example/ directory

set_up() {
    cd example
    export MAKE="make -f ../stacks.mk ENV=dev-eu CLICOLOR_FORCE=0"
}

tear_down() {
    $MAKE deepclean && rm -rf ../registry.opentofu.org
    rm .terraform.lock.hcl
    assert_empty "$(git status --porcelain -- .)"
}

test_plan_apply_refresh_destroy_clean() {
    # Run an initial full plan and apply to have a clean state
    output="$($MAKE plan)"
    assert_matches '\[network/vpc.*Plan.*0 to destroy' "$output"
    assert_matches '\[instances.*Plan.*0 to destroy' "$output"
    assert_matches '\[org.*Plan.*0 to destroy' "$output"
    output="$($MAKE plan)"
    assert_matches 'Nothing to be done for.*plan' "$output"
    touch instances/main.tf
    output="$($MAKE plan)"
    assert_not_matches '\[network/vpc' "$output"
    assert_matches '\[instances.*Plan.*0 to destroy' "$output"
    assert_not_matches '\[org' "$output"
    output="$($MAKE apply)"
    assert_matches '\[network/vpc.*Apply complete' "$output"
    assert_matches '\[instances.*Apply complete' "$output"
    assert_matches '\[org.*Apply complete' "$output"
    output="$($MAKE refresh)"
    assert_matches '\[network/vpc.*Outputs:' "$output"
    assert_matches '\[instances.*Outputs:' "$output"
    assert_matches '\[org.*Outputs:' "$output"
    output="$($MAKE plan)"
    assert_matches '\[network/vpc.*No changes' "$output"
    assert_matches '\[instances.*No changes' "$output"
    assert_matches '\[org.*No changes' "$output"
    output="$($MAKE plan)"
    assert_matches 'Nothing to be done for.*plan' "$output"
    output="$(TF_CLI_ARGS='-auto-approve' $MAKE destroy)"
    assert_matches '\[network/vpc.*Destroy complete' "$output"
    assert_matches '\[instances.*Destroy complete' "$output"
    assert_matches '\[org.*Destroy complete' "$output"
    output="$($MAKE clean)"
    assert_contains "network/vpc/$ENV" "$output"
    assert_contains "instances/$ENV" "$output"
    assert_contains "org/$ENV" "$output"
}

test_targets() {
    output="$($MAKE plan-network)"
    assert_matches '\[network/vpc.*Plan.*0 to destroy' "$output"
    output="$($MAKE plan-network/vpc)"
    assert_matches 'Nothing to be done for.*plan-network/vpc' "$output"
    output="$($MAKE plan-instances)"
    assert_matches '\[instances.*Plan.*0 to destroy' "$output"
}

test_plan_changed() {
    # Run an initial full plan and apply to have a clean state
    $MAKE plan >/dev/null 2>&1
    $MAKE apply >/dev/null 2>&1

    # test dynamic skipping
    echo '# change' >> network/vpc/main.tf
    output=$($MAKE plan-changed DIFF_BASE=HEAD)
    assert_matches '\[network/vpc.*No changes' "$output"
    assert_matches 'Skip.*instances' "$output"
    assert_not_matches '\[org' "$output"
    # test downstream dependencies of changed stacks
    echo 'output "new" { value = 123 }' >> network/vpc/main.tf
    output=$($MAKE plan-changed DIFF_BASE=HEAD)
    assert_matches '\[network/vpc.*Plan.*0 to destroy' "$output"
    assert_matches '\[instances.*Plan.*0 to destroy' "$output"
    assert_not_matches '\[org.*Plan' "$output"
    output=$($MAKE apply-changed DIFF_BASE=HEAD)
    assert_matches '\[network/vpc.*Apply complete' "$output"
    assert_matches '\[instances.*Apply complete' "$output"
    assert_not_matches '\[org.*Apply' "$output"

    # cleanup
    git checkout network/vpc/main.tf
}

test_failed_apply_stale_plan() {
    # break 'instances' main.tf to fail during apply
    echo -e 'resource "terraform_data" "fail" {\nprovisioner "local-exec" {\n command = "exit 1"\n}\n}' >> instances/main.tf
    output=$($MAKE plan)
    assert_matches '\[instances.*Plan.*0 to destroy' "$output"
    # The apply should fail
    ! $MAKE apply >/dev/null 2>&1
    # plan should be stale and get replanned
    output=$($MAKE plan)
    assert_matches 'terraform_data.*fail.*is tainted' "$output"
    assert_matches '\[instances.*Plan.*1 to destroy' "$output"

    # cleanup
    git checkout instances/main.tf
}
