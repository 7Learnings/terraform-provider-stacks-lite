package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-log/tflog"
)

type mapPlanModifier struct {
	providerData *StacksLiteProviderData
}

func (m *mapPlanModifier) Description(ctx context.Context) string {
	return "Reads upstream plan outputs and populates the plan with known values."
}

func (m *mapPlanModifier) MarkdownDescription(ctx context.Context) string {
	return m.Description(ctx)
}

func (m *mapPlanModifier) PlanModifyMap(ctx context.Context, req planmodifier.MapRequest, resp *planmodifier.MapResponse) {
	var stack types.String
	diags := req.Plan.GetAttribute(ctx, req.Path.ParentPath().AtName("stack"), &stack)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}
	if stack.IsNull() || stack.IsUnknown() {
		resp.PlanValue = types.MapUnknown(types.StringType)
		return
	}

	planVal, diagErrors := m.computePlan(ctx, stack.ValueString(), req.StateValue)
	for title, msg := range diagErrors {
		resp.Diagnostics.AddError(title, msg)
	}
	if !resp.Diagnostics.HasError() {
		resp.PlanValue = planVal
	}
}

// computePlan extracts the core logic so it can be cleanly unit tested without mocking tfsdk.Plan.
// Returns the planned map value, and any errors as map[title]message.
func (m *mapPlanModifier) computePlan(ctx context.Context, stack string, stateValue types.Map) (types.Map, map[string]string) {
	pd := m.providerData
	if pd == nil {
		pd = &StacksLiteProviderData{
			StacksRoot: os.Getenv("STACKS_ROOT"),
			Env:        os.Getenv("STACKS_ENV"),
		}
	}

	stackDir := pd.StackDirectoryPath(stack)
	if _, err := os.Stat(stackDir); err != nil {
		if os.IsNotExist(err) {
			return types.MapNull(types.StringType), map[string]string{
				"Upstream stack directory not found": fmt.Sprintf("Stack directory %q does not exist in stacks root %q", stack, pd.StacksRoot),
			}
		}
		return types.MapNull(types.StringType), map[string]string{
			"Error accessing upstream stack directory": fmt.Sprintf("Failed to access stack directory %q: %v", stackDir, err),
		}
	}

	planPath := pd.PlanPath(stackDir)
	tflog.Debug(ctx, "reading upstream plan outputs", map[string]interface{}{
		"path":  planPath,
		"stack": stack,
	})

	data, err := os.ReadFile(planPath)
	if err != nil {
		if os.IsNotExist(err) {
			if stateValue.IsNull() {
				return types.MapUnknown(types.StringType), nil
			}
			// plan with current state if upstream planning could be skipped
			return stateValue, nil
		}
		return types.MapNull(types.StringType), map[string]string{
			"Error reading upstream plan file": fmt.Sprintf("Failed to read upstream plan from %q: %v", planPath, err),
		}
	}

	var plan Plan
	if err := json.Unmarshal(data, &plan); err != nil {
		return types.MapNull(types.StringType), map[string]string{
			"Error unmarshaling upstream plan": fmt.Sprintf("Failed to unmarshal upstream plan from %q: %v", planPath, err),
		}
	}

	outputElements := make(map[string]attr.Value)

	for name, output := range plan.PlannedValues.Outputs {
		if output.Value == nil {
			outputElements[name] = types.StringUnknown()
		} else {
			switch v := output.Value.(type) {
			case string:
				outputElements[name] = types.StringValue(v)
			case float64, float32, int, int32, int64:
				outputElements[name] = types.StringValue(fmt.Sprintf("%v", v))
			case bool:
				outputElements[name] = types.StringValue(fmt.Sprintf("%t", v))
			default:
				valBytes, err := json.Marshal(output.Value)
				if err != nil {
					return types.MapNull(types.StringType), map[string]string{
						fmt.Sprintf("Error marshaling output '%s'", name): err.Error(),
					}
				}
				outputElements[name] = types.StringValue(string(valBytes))
			}
		}
	}

	result, diags := types.MapValue(types.StringType, outputElements)
	if diags.HasError() {
		return types.MapNull(types.StringType), map[string]string{
			"Error creating map value": fmt.Sprintf("Failed to create map from outputs: %v", diags),
		}
	}
	return result, nil
}

func newMapPlanModifier() *mapPlanModifier {
	return &mapPlanModifier{}
}
