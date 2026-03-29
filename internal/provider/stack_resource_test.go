package provider

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/hashicorp/terraform-plugin-testing/helper/resource"
)

func TestAccStacksResource(t *testing.T) {
	// Setup mock stacks_root
	stacksRoot := t.TempDir()
	env := "dev"
	stackName := "my_stack"

	stackDir := filepath.Join(stacksRoot, stackName, env)
	err := os.MkdirAll(stackDir, 0755)
	if err != nil {
		t.Fatalf("failed to create stack directory: %v", err)
	}

	outputsPath := filepath.Join(stackDir, "outputs.json")
	outputs := map[string]interface{}{
		"outputs": map[string]interface{}{
			"simple_string": map[string]interface{}{
				"value":     "hello",
				"sensitive": false,
			},
			"simple_number": map[string]interface{}{
				"value":     42,
				"sensitive": false,
			},
			"simple_bool": map[string]interface{}{
				"value":     true,
				"sensitive": false,
			},
			"complex_list": map[string]interface{}{
				"value":     []string{"a", "b", "c"},
				"sensitive": false,
			},
			"complex_map": map[string]interface{}{
				"value": map[string]string{
					"key": "value",
				},
				"sensitive": false,
			},
		},
	}
	// Wait, the resource logic unmarshals into map[string]OutputValue directly from data!
	// But `tofu` outputs format contains `{"outputs": ...}` at the root?
	// No, `outputs.json` written by tofu/terraform is usually just the outputs map if it's `tofu output -json`
	// Let's re-read stack_resource.go to see what it expects:
	// `var outputs map[string]OutputValue`
	// `if err := json.Unmarshal(data, &outputs); ...`
	// So it expects the root to be a map of string to OutputValue.
	outputsOnly := outputs["outputs"].(map[string]interface{})

	outputsData, err := json.Marshal(outputsOnly)
	if err != nil {
		t.Fatalf("failed to marshal outputs: %v", err)
	}
	err = os.WriteFile(outputsPath, outputsData, 0644)
	if err != nil {
		t.Fatalf("failed to write outputs: %v", err)
	}

	resource.Test(t, resource.TestCase{
		ProtoV6ProviderFactories: testAccProtoV6ProviderFactories,
		Steps: []resource.TestStep{
			{
				Config: fmt.Sprintf(`
terraform {
  required_providers {
    stacks-lite = {
      source = "registry.opentofu.org/hashicorp/stacks-lite"
    }
  }
}

provider "stacks-lite" {
  stacks_root = "%[1]s"
  env         = "%[2]s"
}

resource "stacks" "test" {
  stack = "%[3]s"
  provider = stacks-lite
}
`, filepath.ToSlash(stacksRoot), env, stackName),
				Check: resource.ComposeAggregateTestCheckFunc(
					resource.TestCheckResourceAttr("stacks.test", "stack", stackName),
					resource.TestCheckResourceAttr("stacks.test", "outputs.simple_string", "hello"),
					resource.TestCheckResourceAttr("stacks.test", "outputs.simple_number", "42"),
					resource.TestCheckResourceAttr("stacks.test", "outputs.simple_bool", "true"),
					resource.TestCheckResourceAttr("stacks.test", "outputs.complex_list", `["a","b","c"]`),
					resource.TestCheckResourceAttr("stacks.test", "outputs.complex_map", `{"key":"value"}`),
				),
			},
		},
	})
}

func TestAccStacksResource_MissingOutputs(t *testing.T) {
	stacksRoot := t.TempDir()
	env := "dev"
	stackName := "missing_outputs_stack"

	stackDir := filepath.Join(stacksRoot, stackName, env)
	err := os.MkdirAll(stackDir, 0755)
	if err != nil {
		t.Fatalf("failed to create stack directory: %v", err)
	}

	resource.Test(t, resource.TestCase{
		ProtoV6ProviderFactories: testAccProtoV6ProviderFactories,
		Steps: []resource.TestStep{
			{
				Config: fmt.Sprintf(`
terraform {
  required_providers {
    stacks-lite = {
      source = "registry.opentofu.org/hashicorp/stacks-lite"
    }
  }
}

provider "stacks-lite" {
  stacks_root = "%[1]s"
  env         = "%[2]s"
}

resource "stacks" "test" {
  stack = "%[3]s"
  provider = stacks-lite
}
`, filepath.ToSlash(stacksRoot), env, stackName),
				ExpectError: regexp.MustCompile(`apply outputs file`),
			},
		},
	})
}
