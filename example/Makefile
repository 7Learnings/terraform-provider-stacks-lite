ENV:= # stacks environment, e.g. dev-eu or production-us
TF:=tofu
Q:=@ # run make Q= for verbose output

# TODO: gotcha uncommitted files
FILES:=$(shell git ls-files -- '*.tf' '*.tfvars')

ifeq ($(ENV),)
  $(error 'Must set ENV variable')
endif

# Find all leaf dirs by sorting and eliminating prefixes of succeeding dirs
STACKS := $(shell printf '%s\n' $(sort $(filter-out ./,$(dir $(FILES)))) | \
    awk '{ if (NR > 1 && index($$0, prev) != 1) print prev; prev = $$0 } END { print prev }')

# --- Rules ---

# plan
$(addsuffix $(ENV)/tfplan.json,$(STACKS)): %/$(ENV)/tfplan.json: %/$(ENV)/.terraform
	$(Q)echo "Planning $*"
	$(Q)cd $(@D) && $(TF) plan -lock=false -refresh=false -out=tfplan && $(TF) show -json tfplan > $(@F)

# apply
$(addsuffix $(ENV)/outputs.json,$(STACKS)): %/$(ENV)/outputs.json: %/$(ENV)/tfplan.json
	$(Q)echo "Applying $*"
	$(Q)cd $(@D) && $(TF) apply -json-into=apply.log.json tfplan && tail -n 1 apply.log.json | jq .outputs > $(@F)

# export stacks-lite provider config as environment variables
$(addsuffix $(ENV)/outputs.json,$(STACKS)) $(addsuffix $(ENV)/tfplan.json,$(STACKS)): export STACKS_ROOT=$(shell revpath $(@D))
$(addsuffix $(ENV)/outputs.json,$(STACKS)) $(addsuffix $(ENV)/tfplan.json,$(STACKS)): export STACKS_ENV=$(ENV)

# --- Working Directories ---

$(addsuffix $(ENV),$(STACKS)): # working directories
	$(Q)mkdir -p $@
	$(Q)echo '*' > $@/.gitignore

# --- Terraform Init ---

# Reuse same terraform init for all stacks (globally locked providers and modules)
# TODO: gather and import used modules so they don't have to be declared in providers.tf
$(addsuffix $(ENV)/.terraform,$(STACKS)): %/$(ENV)/.terraform: | .terraform %/$(ENV)/.terraform.lock.hcl %/$(ENV)
	$(Q)ln --relative -sf $(firstword $|) $(@D)/

$(addsuffix $(ENV)/.terraform.lock.hcl,$(STACKS)): %/$(ENV)/.terraform.lock.hcl: | .terraform.lock.hcl %/$(ENV)
	$(Q)ln --relative -sf $(firstword $|) $(@D)/

.terraform .terraform.lock.hcl:
	$(Q)$(TF) init -var=stacks_root=. -var=stacks_env=$(ENV) -var=stack=_
	$(Q)touch $@

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
	rm -rf $(STACKS:%/=%/$(ENV))

# --- Dynamic Dependency Logic ---

# Included will be rebuild before inclusion in the same make invocation (similar to Makefile rules)
deps-$(ENV).d: gen_deps.sh Makefile $(FILES)
	$(Q)./$< "$(ENV)" $(words $(STACKS)) $(STACKS:%/=%) $(FILES) > $@

include deps-$(ENV).d

# Disable legacy builtin suffix rules (https://www.gnu.org/software/make/manual/html_node/Suffix-Rules.html)
.SUFFIXES:
