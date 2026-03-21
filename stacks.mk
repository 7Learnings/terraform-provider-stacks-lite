ENV:= # stacks environment, e.g. dev-eu or production-us
TF:=tofu
Q:=@ # run make Q= for verbose output
TF_PARALLELISM:=128
TF_REFRESH:=false # whether to refresh during plan

# Set DIFF_BASE to compare against (e.g. origin/main, @{upstream}, HEAD~3)
DIFF_BASE:=@{upstream}

SHELL := /usr/bin/env bash

# pipe to prefix TF output with stack name
export CLICOLOR_FORCE=1
.SHELLFLAGS := -o pipefail -c
P = 2>&1 | awk -v s="$*" '{ printf "[%-16s] %s\n", s, $$0; fflush() }'

FILES:=$(filter-out %modules.auto.tf,$(shell git ls-files -- '*.tf' '*.tfvars'))

ifeq ($(ENV),)
  $(error 'Must set ENV variable')
endif
ifneq ($(MAKECMDGOALS),clean)
  UNTRACKED:=$(filter-out %modules.auto.tf,$(shell git ls-files --other --exclude-standard -- '*.tf' '*.tfvars' '*.tfvars.json'))
  ifneq ($(UNTRACKED),)
    $(error 'Found untracked files: $(UNTRACKED)')
  endif
endif

# Find all leaf dirs by sorting and eliminating prefixes of succeeding dirs
# Filter out any modules along the path.
STACKS := $(shell printf '%s\n' $(sort $(filter-out ./ modules/%,$(dir $(FILES)))) | \
    awk '{ if (NR > 1 && index($$0, prev) != 1) print prev; prev = $$0 } END { print prev }')

# --- Rules ---

# plan
$(addsuffix $(ENV)/tfplan.json,$(STACKS)): %/$(ENV)/tfplan.json: %/$(ENV)/.terraform
	$(Q)skip=false; \
	if [ -n "$(filter plan-changed apply-changed,$(MAKECMDGOALS))" ] && \
	   [ -z "$(filter $*,$(_DIRECTLY_CHANGED))" ] && [ -f "$@" ]; then \
	    skip=true; \
	    for up in $(UPSTREAMS_$*); do \
	        if jq -e '.output_changes // {} | to_entries | any(.value.actions != ["no-op"])' \
	            $$up/$(ENV)/tfplan.json >/dev/null 2>&1; then \
	            skip=false; break; \
	        fi; \
	    done; \
	fi; \
	if $$skip; then \
	    echo "Skipping $* (upstream outputs unchanged)"; \
	    echo '{}' > $(@); \
	else \
	    echo "Planning $*" $(P); \
	    cd $(@D) && $(TF) plan -parallelism=$(TF_PARALLELISM) -refresh=$(TF_REFRESH) -lock=$(TF_REFRESH) -out=tfplan $(P) && \
	    $(TF) show -json tfplan > $(@F); \
	fi

# apply
$(addsuffix $(ENV)/outputs.json,$(STACKS)): %/$(ENV)/outputs.json: %/$(ENV)/tfplan.json
	$(Q)echo "Applying $*" $(P)
# Applying downstream stacks also (re-)reads upstream tfplan.json in the final plan validation phase.
# https://github.com/hashicorp/terraform/blob/main/docs/resource-instance-change-lifecycle.md
# https://github.com/opentofu/opentofu/blob/cba3902c0bf20531ee27d6c76e907fa7348b74e6/internal/engine/applying/operations_resource_managed.go#L91
# Because of that we mark tfplans as old rather than to directly delete them, so that they will be rebuild during the next plan.
	$(Q)cd $(@D) && $(TF) apply -parallelism=$(TF_PARALLELISM) -json-into=apply.log.json tfplan $(P) && \
	    tail -n 1 apply.log.json | jq .outputs > $(@F) && \
	    rm tfplan && touch --no-create --time=mtime --date=@0 tfplan.json # mark applied plans as stale

# destroy
$(addsuffix $(ENV)/.destroy,$(STACKS)): %/$(ENV)/.destroy:
	$(Q)echo "Destroying $*" $(P)
	$(Q)cd $(@D) && $(TF) destroy -parallelism=$(TF_PARALLELISM) $(P)

# refresh (actually produces outputs.json for downstream stacks)
$(addsuffix $(ENV)/.refresh,$(STACKS)): %/$(ENV)/.refresh: %/$(ENV)/_vars.auto.tf %/$(ENV)/.terraform
	$(Q)echo "Refreshing $*" $(P)
	$(Q)cd $(@D) && $(TF) refresh -parallelism=$(TF_PARALLELISM) -json-into=refresh.log.json $(P) && \
	    tail -n 1 refresh.log.json | jq .outputs > outputs.json

# export stacks-lite provider config as environment variables
ALL_TARGETS:=$(addsuffix $(ENV)/outputs.json,$(STACKS)) $(addsuffix $(ENV)/tfplan.json,$(STACKS)) $(addsuffix $(ENV)/.destroy,$(STACKS)) $(addsuffix $(ENV)/.refresh,$(STACKS))
$(ALL_TARGETS): export STACKS_ROOT=$(shell revpath $(@D))
$(ALL_TARGETS): export STACKS_ENV=$(ENV)
$(ALL_TARGETS): export TF_CLI_CONFIG_FILE=.terraform.tfrc

# --- Working Directories ---

$(addsuffix $(ENV),$(STACKS)): # working directories
	$(Q)mkdir -p $@
	$(Q)echo '.gitignore' > $@/.gitignore

# --- Terraform Init ---

# Reuse same terraform init for all stacks (globally locked providers and modules)
# TODO: gather and import used modules so they don't have to be declared in providers.tf
$(addsuffix $(ENV)/.terraform,$(STACKS)): %/$(ENV)/.terraform: | .terraform %/$(ENV)/.terraform.lock.hcl %/$(ENV)
	$(Q)ln --relative -sf $(firstword $|) $(@D)/
	$(Q)echo $(@F) >> $(@D)/.gitignore

$(addsuffix $(ENV)/.terraform.lock.hcl,$(STACKS)): %/$(ENV)/.terraform.lock.hcl: | .terraform.lock.hcl %/$(ENV)/.terraform.tfrc %/$(ENV)
	$(Q)ln --relative -sf $(firstword $|) $(@D)/
	$(Q)echo $(@F) >> $(@D)/.gitignore

$(addsuffix $(ENV)/.terraform.tfrc,$(STACKS)): %/$(ENV)/.terraform.tfrc: | .terraform.tfrc %/$(ENV)
	$(Q)ln --relative -sf $(firstword $|) $(@D)/
	$(Q)echo $(@F) >> $(@D)/.gitignore

.terraform.lock.hcl: .terraform
# revpath returns empty string
.terraform: export STACKS_ROOT=.
.terraform: _modules.auto.tf | .terraform.tfrc
	echo $$TF_CLI_CONFIG_FILE
	$(Q)$(TF) init -var=stacks_root=$(STACKS_ROOT) -var=stacks_env=$(STACKS_ENV) -var=stack=root
# symlink relative modules into .terraform dir, so that they are available from each (nested) stack's working dir
	$(Q)sed -nE 's|source = "([^"]+)"|\1|p' $<
	$(Q)ln --relative -sf ./modules/subnet .terraform/modules/
# TODO: use jq
	$(Q)sed -i 's|"modules/|".terraform/modules/|g' .terraform/modules/modules.json

_modules.auto.tf: $(addsuffix $(ENV)/.modules.auto.tf,$(STACKS))
	cat $^ | sort -u > $@

# built provider until it's published
PROVIDER_PATH:=registry.opentofu.org/7learnings/stacks-lite/0.1.0/linux_amd64/terraform-provider-stacks-lite_v0.1.0
.terraform.tfrc: $(dir $(filter %/stacks.mk,$(MAKEFILE_LIST)))$(PROVIDER_PATH)
	$(Q)echo -e 'provider_installation { filesystem_mirror { path = "$(abspath $(dir $(filter %/stacks.mk,$(MAKEFILE_LIST))))" include=["registry.opentofu.org/7learnings/stacks-lite"] } direct {} }\nplugin_cache_dir   = "$$HOME/.local/share/opentofu/plugins"' > $@

$(dir $(filter %/stacks.mk,$(MAKEFILE_LIST)))$(PROVIDER_PATH):
	$(Q)cd $(dir $(filter %/stacks.mk,$(MAKEFILE_LIST))) && go build -o $(PROVIDER_PATH)

$(addsuffix $(ENV)/zzz_stacks.auto.tfvars,$(STACKS)): %/$(ENV)/zzz_stacks.auto.tfvars:
	$(Q){\
		echo "# auto-generated stacks variables for $*/$(ENV)"; \
		echo 'stacks_root = "$(STACKS_ROOT)"'; \
		echo 'stacks_env = "$(STACKS_ENV)"'; \
		echo 'stack = "$*"'; \
	} > $@

$(addsuffix $(ENV)/_vars.auto.tf,$(STACKS)): %/$(ENV)/_vars.auto.tf:
	$(Q){\
		echo "# auto-generated variable declarations for $*/$(ENV)"; \
		sed -nE 's|^\s*([a-zA-Z0-9_-]+)\s*=.*$$|variable "\1" {}|p' $(filter %.tfvars,$^) | sort -u; \
	} > $@
	$(Q)printf '%s\n' $(^F) $(@F) >> $(@D)/.gitignore

$(addsuffix $(ENV)/.modules.auto.tf,$(STACKS)): %/$(ENV)/.modules.auto.tf: $(dir $(lastword $(MAKEFILE_LIST)))stacks-extract-modules.awk %/$(ENV)/_vars.auto.tf
	awk -f $< $(@D)/*.tf | sort -u > $@

# Resort to implicit rules for the symlinks to to avoid multiple wildcard targets or
# having to stamp out a macro for each stack (https://stackoverflow.com/a/74450187)
%.tf:
	$(Q)mkdir -p $(@D)
	$(Q)ln --relative -sf $< $@

%.tfvars:
	$(Q)mkdir -p $(@D)
	$(Q)ln --relative -sf $< $@

.PHONY: clean
clean:
	rm -rf $(STACKS:%/=%/$(ENV)) _modules.auto.tf

.PHONY: deepclean
deepclean: clean
	rm -rf .terraform .terraform.tfrc _modules.auto.tf


# --- Dynamic Dependency Logic ---

# Included will be rebuild before inclusion in the same make invocation (similar to Makefile rules)
deps-$(ENV).d: $(dir $(lastword $(MAKEFILE_LIST)))stacks-gen-deps.sh $(lastword $(MAKEFILE_LIST)) $(FILES)
	$(Q)./$< "$(ENV)" $(words $(STACKS)) $(STACKS:%/=%) $(FILES) > $@
	$(Q)echo 'include deps-$(ENV).d' > .check-cycles-$(ENV).mk
	$(Q)! $(MAKE) -f .check-cycles-$(ENV).mk plan -n 2>&1 | grep -Fi Circular
	$(Q)rm .check-cycles-$(ENV).mk

# used to break cyclic dependency between CHANGED_STACKS and deps.d
.SECONDEXPANSION:

include deps-$(ENV).d

# --- Changed Stacks Detection ---

ifneq ($(filter plan-changed apply-changed changed,$(MAKECMDGOALS)),)
_CHANGED_DIRS := $(sort $(dir $(shell git diff --name-only $(DIFF_BASE) -- "*.tf" "*.tfvars" 2>/dev/null)))
_HAS_ROOT_CHANGE := $(filter ./,$(_CHANGED_DIRS))
_DIRECTLY_CHANGED := $(sort $(if $(_HAS_ROOT_CHANGE),$(STACKS:%/=%),\
    $(foreach d,$(filter-out ./,$(_CHANGED_DIRS)),$(patsubst %/,%,$(filter $(d) $(d)%,$(STACKS))))))
# Expand downstreams transitively (3 iterations)
_CS1 := $(sort $(_DIRECTLY_CHANGED) $(foreach s,$(_DIRECTLY_CHANGED),$(DOWNSTREAMS_$(s))))
_CS2 := $(sort $(_CS1) $(foreach s,$(_CS1),$(DOWNSTREAMS_$(s))))
CHANGED_STACKS := $(sort $(_CS2) $(foreach s,$(_CS2),$(DOWNSTREAMS_$(s))))
endif

.PHONY: plan-changed apply-changed changed
plan-changed: $(CHANGED_STACKS:%=plan-%)
apply-changed: $(CHANGED_STACKS:%=apply-%)
changed:
	@echo '$(if $(CHANGED_STACKS),$(CHANGED_STACKS),(no changed stacks detected))'

# Disable legacy builtin suffix rules (https://www.gnu.org/software/make/manual/html_node/Suffix-Rules.html)
.SUFFIXES:
