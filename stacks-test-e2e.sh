#!/usr/bin/env bashunit

# Run full e2e tests operating on the example/ directory

set_up() {
    shopt -s globstar
    cd example
    ENV=dev-eu
    MAKE="make -f ../stacks.mk ENV=$ENV CLICOLOR_FORCE=0"
}

tear_down() {
    $MAKE deepclean
    rm -f .terraform.lock.hcl
    assert_empty "$(git status --porcelain -- .)"
    shopt -u globstar
}

test_plan_apply_refresh_destroy_clean() {
    # Run an initial full plan and apply to have a clean state
    output="$($MAKE plan)"
    assert_matches "\[$ENV network/vpc.*Plan.*0 to destroy" "$output"
    assert_matches "\[$ENV instances.*Plan.*0 to destroy" "$output"
    assert_matches "\[$ENV org.*Plan.*0 to destroy" "$output"
    output="$($MAKE plan)"
    if [ -n "$output" ]; then # can regenerate .deps files
        assert_matches 'Nothing to be done for.*plan' "$output"
    fi
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
    if [ -n "$output" ]; then # can regenerate .deps files
        assert_matches 'Nothing to be done for.*plan' "$output"
    fi
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
    if [ -n "$output" ]; then # can regenerate .deps files
        assert_matches 'Nothing to be done for.*plan-network/vpc' "$output"
    fi
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

test_separate_plan_apply() {
    # 1. Run an initial full plan and apply to establish the remote state
    $MAKE plan >/dev/null 2>&1
    $MAKE apply >/dev/null 2>&1

    # 2. Make a downstream stack 'instances' newly dependent on upstream stack output
    echo -e 'resource "stacks" "org" {\nstack = "org"\n}' >> instances/main.tf

    # 3. Generate plan for changed stacks
    rm -f **/$ENV/{outputs.json,tfplan,tfplan.json}
    output=$($MAKE plan-changed DIFF_BASE=HEAD 2>&1)
    assert_matches "\[$ENV instances.*Planning" "$output"
    assert_not_matches "\[$ENV org.*Planning" "$output"
    assert_matches 'outputs = \(known after apply\)' "$output"
    assert_file_exists instances/$ENV/tfplan.json
    assert_file_not_exists org/$ENV/tfplan.json

    # 5. Apply only the downstream changed stack
    rm -f **/$ENV/{outputs.json,tfplan,tfplan.json}
    output=$($MAKE apply-changed DIFF_BASE=HEAD)
    assert_matches "\[$ENV instances.*Apply complete" "$output"
    assert_matches "\[$ENV org\s*\] Fetching" "$output"
    assert_not_matches "\[$ENV org\s*\] Apply" "$output"
    assert_file_exists instances/$ENV/outputs.json
    assert_file_exists org/$ENV/outputs.json
    assert_file_not_exists org/$ENV/tfplan.json

    # cleanup
    git checkout instances/main.tf
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

test_deps_hook_contributes_changed() {
    # `instances` colocates a *.nix file (instances/default.nix). The
    # STACKS_DEPS_HOOK (./stacks-deps.sh) reports its extra deps:
    # instances/default.nix plus the shared module in nix/common/. stacks.mk
    # considerers the instances stack _changed_ when any of those changes.
    HOOK="STACKS_DEPS_HOOK=./stacks-deps-nix.sh"

    # 1) a colocated *.nix change re-plans its own stack only
    echo '# change' >> instances/default.nix
    output=$($MAKE changed DIFF_BASE=HEAD $HOOK)
    assert_same 'instances' "$output"
    git checkout -- instances/default.nix

    # 2) a change to a shared nix module re-plans the nix stack that depends on it
    echo '# change' >> nix/common/mod.nix
    output=$($MAKE changed DIFF_BASE=HEAD $HOOK)
    assert_same 'instances' "$output"
    git checkout -- nix/common/mod.nix

    # 3) without the hook, the same non-.tf changes are NOT detected
    echo '# change' >> instances/default.nix
    echo '# change' >> nix/common/mod.nix
    output=$($MAKE changed DIFF_BASE=HEAD)
    assert_same '(no changed stacks detected)' "$output"

    # cleanup
    git checkout -- instances/default.nix nix/common/mod.nix
}

test_deps_hook_direct_plan_on_file_change() {
    # `instances` colocates a *.nix file (instances/default.nix);
    # stacks-gen-deps.sh expands the STACKS_DEPS_HOOK deps into prerequisites
    # of instances/$(ENV)/tfplan.json make target, so a direct plan re-plans
    # `instances` only when a nix source changes.
    HOOK="STACKS_DEPS_HOOK=./stacks-deps-nix.sh"

    # 1) initial plan establishes the tfplan stamp
    $MAKE plan-instances $HOOK >/dev/null 2>&1
    # 2) unchanged nix -> up to date
    output="$($MAKE plan-instances $HOOK)"
    if [ -n "$output" ]; then # can regenerate .deps files
        assert_matches 'Nothing to be done for.*plan-instances' "$output"
    fi
    # 3) a colocated *.nix change re-plans its own stack
    echo '# change' >> instances/default.nix
    output="$($MAKE plan-instances $HOOK)"
    assert_matches "\[$ENV instances.*Plan" "$output"
    # 4) a change to a shared nix module also re-plans the nix stack
    echo '# change' >> nix/common/mod.nix
    output="$($MAKE plan-instances $HOOK)"
    assert_matches "\[$ENV instances.*Plan" "$output"

    # cleanup
    git checkout -- instances/default.nix nix/common/mod.nix
}
