package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-log/tflog"
)

type Plan struct {
	PlannedValues PlannedValues `json:"planned_values"`
}

type PlannedValues struct {
	Outputs map[string]OutputValue `json:"outputs"`
}

type OutputValue struct {
	Value     interface{} `json:"value"`
	Sensitive bool        `json:"sensitive"`
}

type mapPlanModifier struct{}

func (m mapPlanModifier) Description(ctx context.Context) string {
	return "Reads upstream plan outputs and populates the plan with known values."
}

func (m mapPlanModifier) MarkdownDescription(ctx context.Context) string {
	return m.Description(ctx)
}

func (m mapPlanModifier) PlanModifyMap(ctx context.Context, req planmodifier.MapRequest, resp *planmodifier.MapResponse) {
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

	planPath := filepath.Join(stack.ValueString(), "tfplan.json")
	tflog.Debug(ctx, fmt.Sprintf("Reading plan outputs from %s", planPath))

	data, err := os.ReadFile(planPath)
	if err != nil {
		if os.IsNotExist(err) {
			if req.StateValue.IsNull() {
				resp.PlanValue = types.MapUnknown(types.StringType)
			} else {
				// plan with current state if upstream planning could be skipped
				resp.PlanValue = req.StateValue
			}
			return
		}
		resp.Diagnostics.AddError("Error reading upstream plan file", fmt.Sprintf("Failed to read upstream plan from %q: %v", planPath, err))
		return
	}

	var plan Plan
	if err := json.Unmarshal(data, &plan); err != nil {
		resp.Diagnostics.AddError("Error unmarshaling upstream plan", fmt.Sprintf("Failed to unmarshal upstream plan from %q: %v", planPath, err))
		return
	}

	outputElements := make(map[string]attr.Value)

	if !req.State.Raw.IsNull() {
		var state StacksResourceModel
		diags := req.State.Get(ctx, &state)
		resp.Diagnostics.Append(diags...)
		if resp.Diagnostics.HasError() {
			return
		}
		if !state.Outputs.IsNull() {
			for k, v := range state.Outputs.Elements() {
				outputElements[k] = v
			}
		}
	}

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
					resp.Diagnostics.AddError(fmt.Sprintf("Error marshaling output '%s'", name), err.Error())
					return
				}
				outputElements[name] = types.StringValue(string(valBytes))
			}
		}
	}

	resp.PlanValue, diags = types.MapValue(types.StringType, outputElements)
	resp.Diagnostics.Append(diags...)
}

func newMapPlanModifier() planmodifier.Map {
	return mapPlanModifier{}
}
