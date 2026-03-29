package provider

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/types"
)

func TestReadApplyOutputs_Success(t *testing.T) {
	stacksRoot := t.TempDir()
	env := "dev"
	stackName := "my_stack"

	stackDir := filepath.Join(stacksRoot, stackName, env)
	err := os.MkdirAll(stackDir, 0755)
	if err != nil {
		t.Fatalf("failed to create dir: %v", err)
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

	outputsOnly := outputs["outputs"].(map[string]interface{})
	outputsData, err := json.Marshal(outputsOnly)
	if err != nil {
		t.Fatalf("failed to marshal: %v", err)
	}

	err = os.WriteFile(outputsPath, outputsData, 0644)
	if err != nil {
		t.Fatalf("failed to write file: %v", err)
	}

	providerData := &StacksLiteProviderData{
		StacksRoot: stacksRoot,
		Env:        env,
	}

	res := &StacksResource{
		providerData:    providerData,
		mapPlanModifier: &mapPlanModifier{providerData: providerData},
	}

	ctx := context.Background()
	result, err := res.readApplyOutputs(ctx, stackName)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.IsNull() {
		t.Fatalf("expected non-null result")
	}

	elements := result.Elements()
	if elements["simple_string"] != types.StringValue("hello") {
		t.Errorf("expected hello, got %v", elements["simple_string"])
	}
	if elements["simple_number"] != types.StringValue("42") {
		t.Errorf("expected 42, got %v", elements["simple_number"])
	}
	if elements["simple_bool"] != types.StringValue("true") {
		t.Errorf("expected true, got %v", elements["simple_bool"])
	}
	if elements["complex_list"] != types.StringValue(`["a","b","c"]`) {
		t.Errorf(`expected ["a","b","c"], got %v`, elements["complex_list"])
	}
	if elements["complex_map"] != types.StringValue(`{"key":"value"}`) {
		t.Errorf(`expected {"key":"value"}, got %v`, elements["complex_map"])
	}
}

func TestReadApplyOutputs_MissingOutputs(t *testing.T) {
	stacksRoot := t.TempDir()
	env := "dev"
	stackName := "missing_outputs_stack"

	stackDir := filepath.Join(stacksRoot, stackName, env)
	err := os.MkdirAll(stackDir, 0755)
	if err != nil {
		t.Fatalf("failed to create dir: %v", err)
	}

	providerData := &StacksLiteProviderData{
		StacksRoot: stacksRoot,
		Env:        env,
	}

	res := &StacksResource{
		providerData:    providerData,
		mapPlanModifier: &mapPlanModifier{providerData: providerData},
	}

	ctx := context.Background()
	result, err := res.readApplyOutputs(ctx, stackName)
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "apply outputs file") {
		t.Errorf("expected error to contain 'apply outputs file', got: %v", err)
	}
	if !result.IsNull() {
		t.Fatalf("expected null result")
	}
}
