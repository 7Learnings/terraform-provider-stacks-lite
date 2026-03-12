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
