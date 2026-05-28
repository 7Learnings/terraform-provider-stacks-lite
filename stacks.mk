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

# Wrap in wildcard to exclude unstaged deletions
FILES:=$(wildcard $(shell git ls-files -- '*.tf' '*.tfvars'))

ifeq ($(ENV),)
  $(error 'Must set ENV variable')
endif
ifneq ($(MAKECMDGOALS),clean)
  UNTRACKED:=$(filter-out .deps/%.tf,$(shell git ls-files --other --exclude-standard -- '*.tf' '*.tfvars' '*.tfvars.json'))
  ifneq ($(UNTRACKED),)
    $(error 'Found untracked (or deleted) files: $(UNTRACKED)')
  endif
endif

# Find all leaf dirs by sorting and eliminating prefixes of succeeding dirs
# Filter out any modules along the path.
STACKS := $(shell printf '%s\n' $(sort $(filter-out ./ modules/%,$(dir $(FILES)))) | \
    awk '{ if (NR > 1 && index($$0, prev) != 1) print prev; prev = $$0 } END { print prev }')

# --- Rules ---

# plan
$(addsuffix $(ENV)/tfplan.json,$(STACKS)): %/$(ENV)/tfplan.json: %/$(ENV)/.terraform %/$(ENV)/modules
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
	$(Q)cd $(@D) && \
	    touch --no-create --time=mtime --date=@0 tfplan tfplan.json && \
	    $(TF) apply -parallelism=$(TF_PARALLELISM) tfplan $(P) && \
	    rm tfplan && \
	    $(TF) output -json > $(@F)

# destroy
$(addsuffix $(ENV)/.destroy,$(STACKS)): %/$(ENV)/.destroy:
	$(Q)echo "Destroying $*" $(P)
	$(Q)cd $(@D) && $(TF) destroy -parallelism=$(TF_PARALLELISM) $(P)

# refresh (actually produces outputs.json for downstream stacks)
$(addsuffix $(ENV)/.refresh,$(STACKS)): %/$(ENV)/.refresh: %/$(ENV)/.terraform
	$(Q)echo "Refreshing $*" $(P)
	$(Q)cd $(@D) && $(TF) refresh -parallelism=$(TF_PARALLELISM) $(P) && \
	    $(TF) output -json > outputs.json

# https://stackoverflow.com/a/51874794
SPACE:= $() $()

# export stacks-lite provider config as environment variables
ALL_TARGETS:=$(addsuffix $(ENV)/outputs.json,$(STACKS)) $(addsuffix $(ENV)/tfplan.json,$(STACKS)) $(addsuffix $(ENV)/.destroy,$(STACKS)) $(addsuffix $(ENV)/.refresh,$(STACKS))
# make equivalent of $(shell revpath $(@D))
$(ALL_TARGETS): export STACKS_ROOT=$(subst $(SPACE),/,$(foreach w,$(subst /,$(SPACE),$(@D)),..))
$(ALL_TARGETS): export STACKS_ENV=$(ENV)
# separate stack states (gcp/net/vpc → gcp-net-vpc) without reinitializing the backend
# https://opentofu.org/docs/language/state/workspaces/
$(ALL_TARGETS): export TF_WORKSPACE=$(subst /,-,$(patsubst %/,%,$(dir $(@D))))

# --- Working Directories ---

$(addsuffix $(ENV),$(STACKS)): # working directories
	$(Q)mkdir -p $@
	$(Q)echo '.gitignore' > $@/.gitignore

# --- Terraform Init ---

.PHONY: init
init: $(addsuffix $(ENV)/.terraform,$(STACKS))

# Reuse same terraform init for all stacks (globally locked providers and modules)
$(addsuffix $(ENV)/.terraform,$(STACKS)): %/$(ENV)/.terraform: | .terraform %/$(ENV)/modules %/$(ENV)/_vars.auto.tf %/$(ENV)
	$(Q)ln --relative -sf .terraform{,.lock.hcl,rc} $(@D)/
	$(Q)echo .terraform{,.lock.hcl,rc} >> $(@D)/.gitignore

$(addsuffix $(ENV)/modules,$(STACKS)): %/$(ENV)/modules: modules | %/$(ENV)
	$(Q)ln --relative --no-target-directory -sf $< $@

.terraform: .deps/$(ENV).modules.tf .deps/$(ENV).tf.tf
# init all local modules from root "stack"
	$(Q)mkdir -p init/$(ENV)/
# extract all modules across stacks
	$(Q){\
		echo 'variable "stacks_root" {}'; \
		echo 'variable "stacks_env" {}'; \
		echo 'variable "stack" {}'; \
	} > init/$(ENV)/_vars.auto.tf
	$(Q)cp .deps/$(ENV).modules.tf init/$(ENV)/modules.tf
	$(Q)cp .deps/$(ENV).tf.tf init/$(ENV)/tf.tf
	$(Q)ln --relative -sf modules init/$(ENV)/
	$(Q)if [ -f .terraform.lock.hcl ]; then cp .terraform.lock.hcl init/$(ENV)/; fi
	$(Q)cd init/$(ENV)/ && TF_WORKSPACE=init $(TF) init -var=stacks_root=../.. -var=stacks_env=$(STACKS_ENV) -var=stack=init
# patch path to relative modules to use consistent modules symlinks from workdir (to support duplicate modules at different stack depths)
	$(Q)if [ -s init/$(ENV)/modules.tf ]; then sed -Ei 's|Dir":"../../modules|Dir":"modules|g' init/$(ENV)/.terraform/modules/modules.json; fi
	$(Q)rm -rf .terraform{,.lock.hcl} && mv init/$(ENV)/.terraform{,.lock.hcl} .
	$(Q)rm -rf init/$(ENV)

$(addsuffix $(ENV)/zzz_stacks.auto.tfvars,$(STACKS)): %/$(ENV)/zzz_stacks.auto.tfvars:
	$(Q){\
		echo "# auto-generated stacks variables for $*/$(ENV)"; \
		echo 'stacks_root = "$(STACKS_ROOT)"'; \
		echo 'stacks_env = "$(STACKS_ENV)"'; \
		echo 'stack = "$*"'; \
	} > $@

$(addsuffix $(ENV)/_vars.auto.tf,$(STACKS)): %/$(ENV)/_vars.auto.tf: .deps/$(ENV).d # depend on deps file to rebuild on file changes and deletion
	$(Q){\
		echo "# auto-generated variable declarations for $*/$(ENV)"; \
		sed -nE 's|^\s*([a-zA-Z0-9_-]+)\s*=.*$$|variable "\1" {}|p' $(filter %.tfvars,$^) | sort -u; \
	} > $@
	$(Q)printf '%s\n' $(^F) $(@F) >> $(@D)/.gitignore

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
	rm -rf $(STACKS:%/=%/$(ENV)) .deps/$(ENV).d

.PHONY: deepclean
deepclean: clean
	rm -rf .terraform


# --- Dynamic Dependency Logic ---

# Included will be rebuild before inclusion in the same make invocation (similar to Makefile rules)
# Also purge any now dangling symlinks from previous run.
.deps/$(ENV).d: $(dir $(lastword $(MAKEFILE_LIST)))stacks-gen-deps.sh $(lastword $(MAKEFILE_LIST)) .deps/$(ENV).files
	$(Q)if [ -f $@ ]; then \
	    awk -v ORS='\0' -v OFS='\0' -v ENV='$(ENV)' '/_vars\.auto\.tf:/{gsub(/\$$\(ENV\)/,ENV); sub(/.*_vars\.auto\.tf:[[:space:]]*/,""); if(NF){$$1=$$1; print}}' $@ | find -files0-from - -xtype l -delete 2>/dev/null || true; \
	fi
	$(Q)./$< "$(ENV)" $(words $(STACKS)) $(STACKS:%/=%) $(FILES) > $@
	$(Q)echo 'include $@' > $(@D)/check-cycles-$(ENV).mk
	$(Q)! $(MAKE) -f $(@D)/check-cycles-$(ENV).mk plan -n 2>&1 | grep -Fi Circular
	$(Q)rm $(@D)/check-cycles-$(ENV).mk

.deps/$(ENV).files: $(sort $(dir $(FILES))) # depend on dirs to update on file deletion
	$(Q)mkdir -p $(@D)
	$(Q)echo '$(FILES)' | cmp -s - $@ || echo '$(FILES)' > $@

.deps/$(ENV).modules.tf: $(filter %.tf,$(FILES))
	$(Q)awk -f $(dir $(filter %/stacks.mk,$(MAKEFILE_LIST)))stacks-extract-modules.awk $^ > $@.tmp
	$(Q)cmp -s $@.tmp $@ || mv $@.tmp $@
	$(Q)rm -f $@.tmp

.deps/$(ENV).tf.tf: $(filter %.tf,$(FILES))
	$(Q)sed -En '/terraform \{/,/^\}$$/p' $^ > $@.tmp
	$(Q)cmp -s $@.tmp $@ || mv $@.tmp $@
	$(Q)rm -f $@.tmp

# used to break cyclic dependency between CHANGED_STACKS and deps.d
.SECONDEXPANSION:

include .deps/$(ENV).d

# --- Changed Stacks Detection ---

ifneq ($(filter plan-changed apply-changed changed,$(MAKECMDGOALS)),)
_CHANGED_DIRS := $(sort $(dir $(shell git diff --relative --name-only $(DIFF_BASE) -- "*.tf" "*.tfvars" 2>/dev/null)))
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
