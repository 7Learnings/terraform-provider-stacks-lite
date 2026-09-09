#!/usr/bin/env bash
#
# stacks-deps-nix.sh <stack>
#
# Example STACKS_DEPS_HOOK to print a stack's extra dependencies as
# CWD-relative git pathspecs, one per line; prints nothing for a stack with no
# such deps.
#
# Here, a stack that colocates a *.nix file is a "nix stack" that also depends
# on the shared module in nix/common/.

set -euo pipefail

stack="${1:?usage: stacks-deps.sh <stack>}"

shared=(nix/common)

mapfile -t colocated < <(git ls-files -- "${stack}/*.nix")

if (( ${#colocated[@]} == 0 )); then
    exit 0
fi

printf '%s\n' "${colocated[@]}" "${shared[@]}"
