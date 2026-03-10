package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-log/tflog"
)

// Ensure the implementation satisfies the expected interfaces.
var (
	_ resource.Resource = &StacksResource{}
)

// NewStacksResource is a helper function to simplify the provider implementation.
func NewStacksResource(mapPlanModifier *mapPlanModifier) resource.Resource {
	return &StacksResource{
		mapPlanModifier: mapPlanModifier,
	}
}

// StacksResource is the resource implementation.
type StacksResource struct {
	providerData    *StacksLiteProviderData
	mapPlanModifier *mapPlanModifier
}

// StacksResourceModel maps the resource schema data.
type StacksResourceModel struct {
	Stack   types.String `tfsdk:"stack"`
	Outputs types.Map    `tfsdk:"outputs"`
}

func (r *StacksResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = "stacks"
}

func (r *StacksResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}

	data, ok := req.ProviderData.(*StacksLiteProviderData)
	if !ok {
		resp.Diagnostics.AddError(
			"Unexpected Resource Configure Type",
			fmt.Sprintf("Expected *StacksLiteProviderData, got: %T. Please report this issue to the provider developers.", req.ProviderData),
		)
		return
	}

	r.providerData = data
	r.mapPlanModifier.providerData = data
}

func (r *StacksResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Reads the plan outputs from an upstream Terraform stack.",
		Attributes: map[string]schema.Attribute{
			"stack": schema.StringAttribute{
				Description: "The name of the upstream TF stack.",
				Required:    true,
			},
			"outputs": schema.MapAttribute{
				Description: "The outputs from the upstream Terraform stack.",
				Computed:    true,
				ElementType: types.StringType,
				PlanModifiers: []planmodifier.Map{
					r.mapPlanModifier,
				},
			},
		},
	}
}

// Create creates the resource and sets the initial state.
func (r *StacksResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan StacksResourceModel
	diags := req.Plan.Get(ctx, &plan)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}

	outputs, err := r.readApplyOutputs(ctx, plan.Stack.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("Error reading upstream apply outputs", err.Error())
		return
	}

	plan.Outputs = outputs
	diags = resp.State.Set(ctx, &plan)
	resp.Diagnostics.Append(diags...)
}

// Read refreshes the Terraform state with the latest data.
func (r *StacksResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state StacksResourceModel
	diags := req.State.Get(ctx, &state)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}

	outputs, err := r.readApplyOutputs(ctx, state.Stack.ValueString())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return
		}

		resp.Diagnostics.AddError("Error reading upstream apply outputs", err.Error())
		return
	}

	state.Outputs = outputs
	diags = resp.State.Set(ctx, &state)
	resp.Diagnostics.Append(diags...)
}

// Update updates the resource and sets the updated state.
func (r *StacksResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan StacksResourceModel
	diags := req.Plan.Get(ctx, &plan)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}

	outputs, err := r.readApplyOutputs(ctx, plan.Stack.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("Error reading upstream apply outputs", err.Error())
		return
	}

	plan.Outputs = outputs
	diags = resp.State.Set(ctx, &plan)
	resp.Diagnostics.Append(diags...)
}

// Delete deletes the resource and removes it from the Terraform state.
func (r *StacksResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
}

func (r *StacksResource) readApplyOutputs(ctx context.Context, stack string) (types.Map, error) {
	if r.providerData == nil {
		return types.MapNull(types.StringType), fmt.Errorf("provider data not configured")
	}

	stackDir := r.providerData.StackDirectoryPath(stack)
	if _, err := os.Stat(stackDir); err != nil {
		if os.IsNotExist(err) {
			return types.MapNull(types.StringType), fmt.Errorf("stack directory %q does not exist in stacks root %q: %w", stack, r.providerData.StacksRoot, err)
		}
		return types.MapNull(types.StringType), fmt.Errorf("failed to access stack directory %q: %w", stackDir, err)
	}

	outputPath := r.providerData.OutputsPath(stackDir)
	tflog.Debug(ctx, "reading apply outputs", map[string]interface{}{
		"path":  outputPath,
		"stack": stack,
	})

	data, err := os.ReadFile(outputPath)
	if err != nil {
		if os.IsNotExist(err) {
			return types.MapNull(types.StringType), fmt.Errorf("apply outputs file %q not found: ensure the upstream stack has been applied: %w", outputPath, err)
		}
		return types.MapNull(types.StringType), fmt.Errorf("failed to read apply outputs from %q: %w", outputPath, err)
	}

	var outputs map[string]OutputValue
	if err := json.Unmarshal(data, &outputs); err != nil {
		return types.MapNull(types.StringType), fmt.Errorf("failed to unmarshal outputs from %q: %w", outputPath, err)
	}

	outputElements := make(map[string]attr.Value)
	for k, v := range outputs {
		switch val := v.Value.(type) {
		case string:
			outputElements[k] = types.StringValue(val)
		case float64, float32, int, int32, int64:
			outputElements[k] = types.StringValue(fmt.Sprintf("%v", val))
		case bool:
			outputElements[k] = types.StringValue(fmt.Sprintf("%t", val))
		default:
			vBytes, err := json.Marshal(v.Value)
			if err != nil {
				return types.MapNull(types.StringType), fmt.Errorf("failed to marshal output value for key %q in %q: %w", k, outputPath, err)
			}
			outputElements[k] = types.StringValue(string(vBytes))
		}
	}

	result, diags := types.MapValue(types.StringType, outputElements)
	if diags.HasError() {
		return types.MapNull(types.StringType), fmt.Errorf("failed to create map value from outputs: %v", diags)
	}
	return result, nil
}
