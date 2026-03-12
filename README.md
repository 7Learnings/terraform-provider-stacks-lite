# stacks-lite

Simple tooling for native TF micro-stacks with dependencies.

## 1. High-Level Goals

The philosophy of this framework is to simplify Terraform management by adhering to a few core principles:

*   **Simplicity:** Focus on a minimal set of concepts, avoiding complex abstractions or templating engines.
*   **Pure HCL:** The entire codebase is standard HCL, which provides excellent support from IDEs, linters, and other standard tooling.
*   **Explicit Dependencies:** A robust mechanism allows for declaring and planning dependencies between stacks *before* applying any changes.
*   **Automation-Driven:** A simple build system (e.g., `Makefile`) is used to orchestrate all Terraform actions, ensuring consistency and reliability.

Based on an idea from [cisco-open/stacks: Stacks, the Terraform code pre-processor](https://github.com/cisco-open/stacks) (see [intro](https://github.com/cisco-open/stacks/blob/main/docs/2.2.%20I%20am%20starting%20from%20scratch.md)), developed further while trying to scale a multi-tenant TF state.

## 2. Installation

Install as git submodule then include the stacks.mk in your top-level Makefile.

## 2. Directory Layout

The project uses a hierarchical directory structure where code (`.tf`) and configuration (`.tfvars`) can be placed at any level, allowing for easy sharing. Stacks are simply the "leaf" directories in this structure.

```
stacks/
├── Makefile                            # The automation driver for the project (`include stacks-lite/stacks.mk`).
├── stacks-lite                         # The git submodule of this repo.
├── backend.tf                          # A global Terraform backend configuration shared by all stacks.
├── providers.tf                        # A global provider configuration shared by all stacks.
├── all.tfvars                          # Variables for all stacks common to all envs.
├── dev.tfvars                          # Variables for all stacks used in dev envs.
├── prod.tfvars
├── dev-eu.tfvars
├── org/                                # A simple, non-nested stack.
│   └── main.tf
└── network/
    ├── all.tfvars                      # Variables for the network stacks common to all envs.
    ├── eu.tfvars                       # Variables for the network stacks used in eu envs.
    ├── us.tfvars
    ├── netplan.tf                      # A shared `.tf` file injected into all network stacks (useful for e.g. `locals`)
    └── vpc/                            # A nested stack. Note that its internal `.tf` file structure is flexible.
        ├── common.tfvars               # Variables for the vpc stack common to all envs.
        ├── prod-eu.tfvars              # Override for prod-eu env.
        ├── main.tf
        └── subnets.tf
```

## 3. Core Concepts: A Walkthrough

The following examples demonstrate how code and configuration are assembled and executed.

### 3.1 Example 1: The Base `vpc` Stack

This walkthrough explains how the code and configuration for a single stack are collected and processed for a specific environment.

**Scenario:** We want to plan the `network/vpc` stack for `ENV=dev-eu`.

#### Flattening (`.tf` Layers)

The tooling assembles a stack's "layer" by collecting *all* `.tf` files from the project root down to the stack's directory. This means you can structure your code within a stack directory however you see fit (e.g., `main.tf`, `variables.tf`, etc.); all `.tf` files found will be included.

For the `vpc` stack, the aggregated layer would include:
*   `./backend.tf`
*   `./providers.tf`
*   `./network/netplan.tf`
*   `./network/vpc/main.tf`
*   `./network/vpc/subnets.tf`

Note: During flattening files are prefixed with their path to not collide, e.g. `network/netplan.tf` is symlinked to `network_netplan.tf`.

#### Configuration Loading & Precedence (`.tfvars`)

Configuration is selected using a pseudo-hierarchical tag system based on the `ENV` variable and the names of `.tfvars` files. We internally structure the `ENV` variable as `<env>-<location>` (e.g., `prod-us`), but it could also be `<env>-<location>-<shard>` (e.g., `prod-us-01`) or `<env>-<location>-<country>` (e.g., `dev-eu-fr`).

**Selection:** A `.tfvars` file is selected if its name (excluding the extension) is a hyphen-separated, ordered, and contiguous subset of the tags in the `ENV` variable. A special `common.tfvars` file is always selected.

*   An `ENV` of `dev-eu-fr` is treated as having the tags `[dev, eu, fr]`.
*   A file named `dev-eu.tfvars` is selected because `[dev, eu]` is an ordered, contiguous subset of `[dev, eu, fr]`.
*   A file named `dev-fr.tfvars` is **not** selected because `[dev, fr]` is not a contiguous subset. This encourages a clean hierarchical structure.
*   A file named `prod.tfvars` (`[prod]`) would not be selected for `ENV=dev-eu-fr`.

**Precedence:** To ensure that specific configurations override general ones, `.tfvars` files are loaded in a precise order. Variables from files loaded later override those from files loaded earlier. Precedence is determined by the following rules, from lowest to highest:

1.  **Path Specificity:** Files in deeper directories have higher precedence. (e.g., `network/common.tfvars` overrides `common.tfvars`).
2.  **Tag Position:** Files matching tags that appear earlier in the `ENV` string have higher precedence. (e.g., for `ENV=dev-eu`, `dev.tfvars` overrides `eu.tfvars`).
3.  **Tag Specificity:** Files matching more tags have higher precedence. (e.g., `dev-eu.tfvars` overrides both `dev.tfvars` and `eu.tfvars`).

**Example of Loading Order**

Let's assume `ENV=dev-eu-fr` and we are planning the `network/vpc` stack, with the following files present:

```
stacks/
├── common.tfvars
├── dev.tfvars
├── eu.tfvars
├── fr.tfvars
├── dev-eu.tfvars
└── network/
    ├── common.tfvars
    ├── eu.tfvars
    └── vpc/
        └── dev.tfvars
```

The automation tooling would process these files in the following order (from lowest to highest precedence):

| Precedence  | File Path                       | Reason                                                         |
|:------------|:--------------------------------|:---------------------------------------------------------------|
| 1 (Lowest)  | `all.tfvars`             | Root path, common file.                                        |
| 2           | `fr.tfvars`              | Root path, matches last tag (`fr`).                            |
| 3           | `eu.tfvars`              | Root path, matches middle tag (`eu`).                          |
| 4           | `dev.tfvars`             | Root path, matches first tag (`dev`).                          |
| 5           | `dev-eu.tfvars`          | Root path, matches first tag (`dev`), longer match (`dev-eu`). |
| 6           | `network/common.tfvars`  | Deeper path, common file.                                      |
| 7           | `network/eu.tfvars`      | Deeper path, matches middle tag.                               |
| 8 (Highest) | `network/vpc/dev.tfvars` | Deepest path, matches first tag.                               |

Variables in files loaded later override those from files loaded earlier. All of them take precedence over environment variables (discouraging impure ad-hoc builds).

Note: This is implemented by prefixing files with their path and their reverse index of the tag match, e.g. `dev-eu.tfvars` is symlinked to `_3-dev-eu.auto.tfvars`, while `network/eu.tfvars` would be symlinked to `network_2-eu.auto.tfvars`.

#### The "Escape Hatch": Conditional Resources

While this architecture discourages per-environment resources, they are possible when necessary. The recommended pattern is to use `var.env` with the `lifecycle.enabled` meta-argument to toggle between a `resource` and a `data` block. This allows one environment to "own" a shared resource while others access it as a read-only data source.

Here is an example for a `google_project` resource owned by the `production` environment:

```hcl
variable "env" {}
variable "project_id" {}

# Owned and managed by the "production" environment
resource "google_project" "test" {
  name       = "Test"
  project_id = var.project_id

  lifecycle {
    enabled = var.env == "production"
  }
}

# Imported by "production" to adopt the existing resource
import {
  for_each = toset(var.env == "production" ? [var.project_id] : [])
  id       = each.key
  to       = google_project.test
}

# Queried as a data source by all non-production environments
data "google_project" "test" {
  project_id = var.project_id

  lifecycle {
    enabled = var.env != "production"
  }
}

# A single, unified output works for all environments
output "project_number" {
  value = var.env == "production" ? google_project.test.number : data.google_project.test.number
}
```

### 3.2 Example 2: The `instances` Stack & Cross-Stack Planning

This walkthrough explains how a stack can depend on the *planned changes* of another stack.

**Scenario:** We plan a hypothetical `instances` stack (`ENV=dev-eu`), which needs the ID of the VPC from the `vpc` stack.

#### Introducing `stacks` resource

To create a dependency between stacks *before* they are applied, we use the custom `stacks-lite` provider instead of the standard `terraform_remote_state` data source.

Inside the `instances` stack's code, you would declare the dependency like this:
```hcl
resource "stacks" "vpc" {
  # Stack is relative to the stacks root directory
  stack = "network/vpc"
}
```
This resource tells the tooling that this stack depends on the `vpc` stack.

*   **How it Works:** The `stack` resource reads the `tfplan.json` output file from the `vpc` stack's plan. This means it can access the *planned* values of the `vpc` stack's outputs, correctly propagating dependencies that are not yet applied. When the upstream stack did not change and was skipped during planning, the resource uses it's previous outputs state.
*   **Explicit Contract:** By design, the `stack` resouce only exposes the `outputs` of the upstream stack. This ensures a stable and explicit contract between stacks, preventing brittle dependencies on internal resource attributes.

You can then use the outputs in your code:
```hcl
resource "google_compute_instance" "default" {
  // ...
  network_interface {
    # Use the planned output from the vpc stack
    network = stacks.vpc.outputs["vpc_id"]
  }
}
```

## 4. The Automation Driver (`Makefile`) & Execution Model

The entire workflow is orchestrated by a `Makefile` (or a similar build tool) that automates all the steps.

*   **Role of the `Makefile`:** To provide a consistent interface for planning and applying stacks (e.g., `make plan STACK=network/vpc ENV=dev-eu`).
*   **Key Responsibilities:**
    1.  **Centralized `init`:** It runs `terraform init` once at the project root to download providers. The resulting `.terraform` directory is shared by all subsequent operations.
    1.  **Dependency Graph:** It inspects the source code for referenced stacks to build a dependency graph, ensuring that it plans and applies stacks in the correct order.
    1.  **Execution Workspace:** It creates a temporary, isolated workspace directory for each env (e.g., `network/vpc/dev-eu/`).
    3.  **Symlinking:** It populates this workspace with symlinks to the applicable `.tf` files (the code) and `.tfvars` files (the configuration).
    4.  **Command Execution:** It runs the `tofu` command (e.g., `tofu plan`) inside this isolated workspaces (also concurrently with `make -j`).
    6.  **Targeting:** It only plans stacks that have changes and their dependent/downstream stacks (by comparing changes against the remote-tracking branch and using make's native mtime support).

  Usage examples

  make plan-changed                      # diff vs @{upstream}
  make plan-changed DIFF_BASE=origin/main  # diff vs specific branch
  make plan-changed DIFF_BASE=HEAD~3       # diff vs 3 commits ago
  make changed DIFF_BASE=HEAD              # just list affected stacks
  make plan                              # unchanged — plans everything with full deps
