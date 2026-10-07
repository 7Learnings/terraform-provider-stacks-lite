# Stacks reading JSON files declare them as extra deps (before including stacks.mk):
# a stack's own *.json files plus the shared ones in common/.
JSON_COMMON := $(wildcard common/*.json)
JSON_STACKS := $(filter-out . common,$(patsubst %/,%,$(sort $(dir $(shell git ls-files -- '*.json')))))
$(foreach s,$(JSON_STACKS),$(eval EXTRA_DEPS_$(s) := $(wildcard $(s)/*.json) $(JSON_COMMON)))

include ../stacks.mk
