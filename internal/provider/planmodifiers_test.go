package provider

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/types"
)

func TestComputePlan_Success(t *testing.T) {
	stacksRoot := t.TempDir()
	env := "dev"
	stackName := "my_stack"

	stackDir := filepath.Join(stacksRoot, stackName, env)
	err := os.MkdirAll(stackDir, 0755)
	if err != nil {
		t.Fatalf("failed to create dir: %v", err)
	}

	planPath := filepath.Join(stackDir, "tfplan.json")
	planData := Plan{
		PlannedValues: PlannedValues{
			Outputs: map[string]OutputValue{
				"known_string":  {Value: "hello"},
				"known_number":  {Value: 42},
				"known_bool":    {Value: true},
				"unknown_value": {Value: nil}, // Unknown values are nil in tfplan.json outputs
				"complex":       {Value: map[string]interface{}{"key": "value"}},
			},
		},
	}
	planBytes, _ := json.Marshal(planData)
	os.WriteFile(planPath, planBytes, 0644)

	providerData := &StacksLiteProviderData{
		StacksRoot: stacksRoot,
		Env:        env,
	}

	mod := &mapPlanModifier{providerData: providerData}

	stateValue := types.MapNull(types.StringType)

	ctx := context.Background()
	result, diags := mod.computePlan(ctx, stackName, stateValue)
	if len(diags) > 0 {
		t.Fatalf("expected no diags, got: %v", diags)
	}
	if result.IsNull() {
		t.Fatalf("expected non-null result")
	}

	elements := result.Elements()
	if elements["known_string"] != types.StringValue("hello") {
		t.Errorf("expected hello, got %v", elements["known_string"])
	}
	if elements["known_number"] != types.StringValue("42") {
		t.Errorf("expected 42, got %v", elements["known_number"])
	}
	if elements["known_bool"] != types.StringValue("true") {
		t.Errorf("expected true, got %v", elements["known_bool"])
	}
	if elements["complex"] != types.StringValue(`{"key":"value"}`) {
		t.Errorf(`expected {"key":"value"}, got %v`, elements["complex"])
	}
	if !elements["unknown_value"].IsUnknown() {
		t.Errorf("expected unknown value for 'unknown_value', got %v", elements["unknown_value"])
	}
}

func TestComputePlan_MissingPlanFile(t *testing.T) {
	stacksRoot := t.TempDir()
	env := "dev"
	stackName := "my_stack"

	stackDir := filepath.Join(stacksRoot, stackName, env)
	os.MkdirAll(stackDir, 0755)

	providerData := &StacksLiteProviderData{
		StacksRoot: stacksRoot,
		Env:        env,
	}

	mod := &mapPlanModifier{providerData: providerData}

	// 1. No state value -> should return MapUnknown
	stateValue := types.MapNull(types.StringType)

	ctx := context.Background()
	result, diags := mod.computePlan(ctx, stackName, stateValue)
	if len(diags) > 0 {
		t.Fatalf("expected no diags, got: %v", diags)
	}
	if !result.IsUnknown() {
		t.Fatalf("expected unknown result, got: %v", result)
	}

	// 2. With state value -> should return state value
	stateElements := map[string]types.String{
		"test": types.StringValue("old"),
	}
	stateMap, _ := types.MapValueFrom(ctx, types.StringType, stateElements)
	result, diags = mod.computePlan(ctx, stackName, stateMap)
	if len(diags) > 0 {
		t.Fatalf("expected no diags, got: %v", diags)
	}
	if !result.Equal(stateMap) {
		t.Fatalf("expected state map to be returned, got: %v", result)
	}
}
