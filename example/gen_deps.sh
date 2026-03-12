#!/usr/bin/env bash
set -euo pipefail

ENV=$1
NSTACKS=$2
STACKS=("${@:3:$NSTACKS}")
FILES=("${@:3+NSTACKS}")

# Validate stack names: each path component must start with a letter.
for stack in "${STACKS[@]}"; do
    IFS='/' read -ra parts <<< "$stack"
    for part in "${parts[@]}"; do
        if ! [[ "$part" =~ ^[a-zA-Z] ]]; then
            echo "Error: Invalid stack path: '$stack'. Component '$part' must start with a letter." >&2
            exit 1
        fi
    done
done

# regex matching any file in dir or any of it's parents (whole branch)
along_branch_re() {
    local dir=$1

    re="^($dir/"
    while [[ "$dir" == */* ]]; do
        dir="${dir%/*}" # dirname
        re+="|$dir/"
    done
    re+="|)[^/]+"
    echo "$re"
}

# match $1=tfvars file with $2=ENV
# dash-separated tags must be a contiguous subset of ENV tags
# returns precedence of match
env_match() {
    local tfvar_tags=$1-
    local env_tags=$2-

    if [[ "$tfvar_tags" == 'all-' ]]; then
        echo 0
        return 0
    fi

    # Check for contiguous subset.
    local pfx_tags="${env_tags%%$tfvar_tags*}"
    if [[ "$pfx_tags" == "$env_tags" ]]; then
        return 1 # No match
    fi

    # Precedence prioritizes earlier matches. The score is the number of tags
    # (counted by dashes) in the name plus in the remainder.
    local num_env_tags=${env_tags//[^-]}
    local num_pfx_tags=${pfx_tags//[^-]}
    echo $(( ${#num_env_tags} - ${#num_pfx_tags} ))
}

# Call functions based on arguments, unless sourced (e.g., by bashunit)
if (return 0 2>/dev/null); then
    return 0
fi

echo "# Auto-generated dependencies for ENV: $ENV"
for op in plan apply; do
    echo "${op}: ${STACKS[@]/#/$op-}"
done

for stack in "${STACKS[@]}"; do
    echo "" # Separator for readability

    echo "plan-$stack: $stack/\$(ENV)/tfplan.json"
    echo "apply-$stack: $stack/\$(ENV)/outputs.json"

    # 4. Build the path hierarchy pattern to match any inherited files
    pattern="$(along_branch_re "$stack")"

    # 5. Optimized Filtering: Use Bash internal regex matching
    # Filter .tf files
    declare -A deps
    for f in "${FILES[@]}"; do
        if [[ $f =~ $pattern\.tf$ ]]; then
            deps["$f"]="${f//\//_}"
        fi
    done

    # cross-stack deps
    echo -e '# Cross-stack dependencies'
    mapfile -t upstreams < <(sed -nE "s|.*\bstack\s*=\s*\"([^\"]+)\"|\1|p" "${!deps[@]}" 2>/dev/null)
    for upstream in "${upstreams[@]}"; do
        # When running plan-changed/apply-changed, only depend on upstream if it's also in CHANGED_STACKS
        # Using .SECONDEXPANSION to defer evaluation of CHANGED_STACKS because it's calculation cyclically depends on the generated dependency file itself (DOWNSTREAMS_x)
        echo "$stack/\$(ENV)/tfplan.json: \$(if \$(filter plan-changed apply-changed,\$(MAKECMDGOALS)),\$\$(if \$\$(filter $upstream,\$\$(CHANGED_STACKS)),$upstream/\$(ENV)/tfplan.json),$upstream/\$(ENV)/tfplan.json)"
        echo "$stack/\$(ENV)/outputs.json: \$(if \$(filter plan-changed apply-changed,\$(MAKECMDGOALS)),\$\$(if \$\$(filter $upstream,\$\$(CHANGED_STACKS)),$upstream/\$(ENV)/outputs.json),$upstream/\$(ENV)/outputs.json)"
        echo "DOWNSTREAMS_$upstream += $stack"
    done

    # Filter .tfvars with exact ENV matching logic
    for f in "${FILES[@]}"; do
        if [[ $f =~ $pattern\.tfvars$ ]]; then
            base="$f"
            [[ $base == */* ]] && base="${f##*/}" # dirname
            base="${base%.tfvars}"
            if prec=$(env_match "$base" "$ENV"); then
                if [[ $f == */* ]]; then
                    dir="${f%/*}" # dirname
                else
                    dir=''
                fi
                # e.g. network_2-eu-.auto.tfvars to ensure lexical ordering
                # https://opentofu.org/docs/language/values/variables/#variable-definition-precedence
                deps["$f"]="${dir//\//_}${dir:+_}$prec-${base}-.auto.tfvars"
            fi
        fi
    done
    # symlink deps for implicit target
    echo -e '# Generated variable declarations'
    echo "$stack/\$(ENV)/tfplan.json: $stack/\$(ENV)/_vars.auto.tf"
    echo "$stack/\$(ENV)/_vars.auto.tf: ${deps[*]/#/$stack/\$(ENV)/} $stack/\$(ENV)/zzz_stacks.auto.tfvars"
    echo -e '# Symlinks'
    for d in "${!deps[@]}"; do
        echo "$stack/\$(ENV)/${deps[$d]}: $d"
    done
    echo

    unset deps
done
