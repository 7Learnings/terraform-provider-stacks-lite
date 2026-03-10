// Copyright IBM Corp. 2021, 2025
// SPDX-License-Identifier: MPL-2.0

package provider

import (
	"context"
	"os"
	"path/filepath"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/provider/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

// Ensure StacksLiteProvider satisfies various provider interfaces.
var _ provider.Provider = &StacksLiteProvider{}

// StacksLiteProvider defines the provider implementation.
type StacksLiteProvider struct {
	// version is set to the provider version on release, "dev" when the
	// provider is built and ran locally, and "test" when running acceptance
	// testing.
	version         string
	mapPlanModifier *mapPlanModifier
}

type StacksLiteProviderModel struct {
	StacksRoot types.String `tfsdk:"stacks_root"`
	Env        types.String `tfsdk:"env"`
}

type StacksLiteProviderData struct {
	StacksRoot string
	Env        string
}

func (d *StacksLiteProviderData) PlanPath(stack string) string {
	return filepath.Join(d.StacksRoot, stack, d.Env, "tfplan.json")
}

func (d *StacksLiteProviderData) OutputsPath(stack string) string {
	return filepath.Join(d.StacksRoot, stack, d.Env, "outputs.json")
}

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

func (p *StacksLiteProvider) Metadata(ctx context.Context, req provider.MetadataRequest, resp *provider.MetadataResponse) {
	resp.TypeName = "stacks-lite"
	resp.Version = p.version
}

func (p *StacksLiteProvider) Schema(ctx context.Context, req provider.SchemaRequest, resp *provider.SchemaResponse) {
	resp.Schema = schema.Schema{
		Attributes: map[string]schema.Attribute{
			"stacks_root": schema.StringAttribute{
				Description: "The root directory where the stacks are located. Can also be set with STACKS_ROOT environment variable.",
				Optional:    true,
			},
			"env": schema.StringAttribute{
				Description: "The environment name. Can also be set with STACKS_ENV environment variable.",
				Optional:    true,
			},
		},
	}
}

func (p *StacksLiteProvider) Configure(ctx context.Context, req provider.ConfigureRequest, resp *provider.ConfigureResponse) {
	var data StacksLiteProviderModel
	diags := req.Config.Get(ctx, &data)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}

	stacksRoot := os.Getenv("STACKS_ROOT")
	if !data.StacksRoot.IsNull() {
		stacksRoot = data.StacksRoot.ValueString()
	}

	env := os.Getenv("STACKS_ENV")
	if !data.Env.IsNull() {
		env = data.Env.ValueString()
	}

	providerData := &StacksLiteProviderData{
		StacksRoot: stacksRoot,
		Env:        env,
	}

	p.mapPlanModifier.providerData = providerData

	resp.DataSourceData = providerData
	resp.ResourceData = providerData
}

func (p *StacksLiteProvider) Resources(ctx context.Context) []func() resource.Resource {
	return []func() resource.Resource{
		func() resource.Resource {
			return NewStacksResource(p.mapPlanModifier)
		},
	}
}

func (p *StacksLiteProvider) DataSources(ctx context.Context) []func() datasource.DataSource {
	return []func() datasource.DataSource{}
}

func New(version string) func() provider.Provider {
	return func() provider.Provider {
		return &StacksLiteProvider{
			version:         version,
			mapPlanModifier: newMapPlanModifier(),
		}
	}
}
