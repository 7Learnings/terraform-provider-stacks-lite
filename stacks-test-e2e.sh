#!/usr/bin/env bashunit

# Run full e2e tests operating on the example/ directory

set_up() {
    cd example
    ENV=dev-eu
    MAKE="make -f ../stacks.mk ENV=$ENV CLICOLOR_FORCE=0"
}

tear_down() {
    $MAKE deepclean
    rm .terraform.lock.hcl
    assert_empty "$(git status --porcelain -- .)"
}

test_plan_apply_refresh_destroy_clean() {
    # Run an initial full plan and apply to have a clean state
    output="$($MAKE plan)"
    assert_matches "\[$ENV network/vpc.*Plan.*0 to destroy" "$output"
    assert_matches "\[$ENV instances.*Plan.*0 to destroy" "$output"
    assert_matches "\[$ENV org.*Plan.*0 to destroy" "$output"
    output="$($MAKE plan)"
    assert_empty "$output" # recreates .deps files manifest
    touch instances/main.tf
    output="$($MAKE plan)"
    assert_not_matches "\[$ENV network/vpc" "$output"
    assert_matches "\[$ENV instances.*Plan.*0 to destroy" "$output"
    assert_not_matches "\[$ENV org" "$output"
    output="$($MAKE apply)"
    assert_matches "\[$ENV network/vpc.*Apply complete" "$output"
    assert_matches "\[$ENV instances.*Apply complete" "$output"
    assert_matches "\[$ENV org.*Apply complete" "$output"
    output="$($MAKE refresh)"
    assert_matches "\[$ENV network/vpc.*Outputs:" "$output"
    assert_matches "\[$ENV instances.*Outputs:" "$output"
    assert_matches "\[$ENV org.*Outputs:" "$output"
    output="$($MAKE plan)"
    assert_matches "\[$ENV network/vpc.*No changes" "$output"
    assert_matches "\[$ENV instances.*No changes" "$output"
    assert_matches "\[$ENV org.*No changes" "$output"
    output="$($MAKE plan)"
    assert_empty "$output" # recreates .deps files manifest
    output="$(TF_CLI_ARGS='-auto-approve' $MAKE destroy)"
    assert_matches "\[$ENV network/vpc.*Destroy complete" "$output"
    assert_matches "\[$ENV instances.*Destroy complete" "$output"
    assert_matches "\[$ENV org.*Destroy complete" "$output"
    output="$($MAKE clean)"
    assert_contains "network/vpc/$ENV" "$output"
    assert_contains "instances/$ENV" "$output"
    assert_contains "org/$ENV" "$output"
}

test_targets() {
    output="$($MAKE plan-network)"
    assert_matches "\[$ENV network/vpc.*Plan.*0 to destroy" "$output"
    output="$($MAKE plan-network/vpc)"
    assert_empty "$output" # recreates .deps files manifest
    output="$($MAKE plan-instances)"
    assert_matches "\[$ENV instances.*Plan.*0 to destroy" "$output"
}

test_plan_changed() {
    # Run an initial full plan and apply to have a clean state
    $MAKE plan >/dev/null 2>&1
    $MAKE apply >/dev/null 2>&1

    # test dynamic skipping
    echo '# change' >> network/vpc/main.tf
    output=$($MAKE plan-changed DIFF_BASE=HEAD)
    assert_matches "\[$ENV network/vpc.*No changes" "$output"
    assert_matches 'Skip.*instances' "$output"
    assert_not_matches "\[$ENV org" "$output"
    # test downstream dependencies of changed stacks
    echo 'output "new" { value = 123 }' >> network/vpc/main.tf
    output=$($MAKE plan-changed DIFF_BASE=HEAD)
    assert_matches "\[$ENV network/vpc.*Plan.*0 to destroy" "$output"
    assert_matches "\[$ENV instances.*Plan.*0 to destroy" "$output"
    assert_not_matches "\[$ENV org.*Plan" "$output"
    output=$($MAKE apply-changed DIFF_BASE=HEAD)
    assert_matches "\[$ENV network/vpc.*Apply complete" "$output"
    assert_matches "\[$ENV instances.*Apply complete" "$output"
    assert_not_matches "\[$ENV org.*Apply" "$output"

    # cleanup
    git checkout network/vpc/main.tf
}

test_failed_apply_stale_plan() {
    # break 'instances' main.tf to fail during apply
    echo -e 'resource "terraform_data" "fail" {\nprovisioner "local-exec" {\n command = "exit 1"\n}\n}' >> instances/main.tf
    output=$($MAKE plan)
    assert_matches "\[$ENV instances.*Plan.*0 to destroy" "$output"
    # The apply should fail
    ! $MAKE apply >/dev/null 2>&1
    # plan should be stale and get replanned
    output=$($MAKE plan)
    assert_matches 'terraform_data.*fail.*is tainted' "$output"
    assert_matches "\[$ENV instances.*Plan.*1 to destroy" "$output"

    # cleanup
    git checkout instances/main.tf
}

test_file_deletion() {
    touch network/vpc/dummy.tf
    git add network/vpc/dummy.tf
    output=$($MAKE plan-network/vpc)
    assert_matches "\[$ENV network/vpc.*Plan.*0 to destroy" "$output"
    git rm -f network/vpc/dummy.tf
    output=$($MAKE plan-network/vpc)
    assert_matches "\[$ENV network/vpc.*Plan.*0 to destroy" "$output"
}
