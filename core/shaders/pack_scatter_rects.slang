module pack_scatter_rects;

import pulse_echo_common;
import util;

[[vk::push_constant]]
public ConstantBuffer<PackScatterRectSettings> settings;

float aperture_power_denominator_cumulative(in float4 rect_samples, in float dt, in float dt2)
{
	// TODO(rnp): is this supposed to be floating point equal? seems suspicious
	return rect_samples.x == rect_samples.w ? dt : dt2;
}

float aperture_power_denominator(in float4 rect_samples, in float dt, in float dt2)
{
	// TODO(rnp): is this supposed to be floating point equal? seems suspicious
	return rect_samples.w - rect_samples.x <= 1 ? dt : dt2;
}

// TODO(rnp): spec constants
#ifndef GROUP_SIZE_X
#define GROUP_SIZE_X 4
#endif

// TODO(rnp): this needs to be determined at runtime.
// We only know the scatter batch size at runtime so
// GROUP_SIZE_X cannot be optimally predetermined.
[shader("compute")]
[numthreads(GROUP_SIZE_X, 4, 4)]
void main(uint3 GlobalInvocationID: SV_DispatchThreadID)
{
	uint scatter_index  = GlobalInvocationID.x;
	uint receive_index  = GlobalInvocationID.y;
	uint transmit_index = GlobalInvocationID.z;

	uint3 dispatch_test = uint3(settings.scatterBatchCount, settings.receiveCount, settings.transmitCount);
	if (any(GlobalInvocationID >= dispatch_test))
		return;

	RectangularAperture r_aperture = receiveApertures[receive_index];
	RectangularAperture t_aperture = transmitApertures[transmit_index];
	Scatter             scatter    = scatters[settings.scatterBatchOffset + scatter_index];

	float fs = settings.samplingFrequency;
	float dt = 1.f / fs;

	// NOTE(rnp): transmit relative values
	float4x4 t_aperture_transform = mul(rotate(t_aperture.normal, float3(0, 0, 1)),
	                                    translate(t_aperture.position, 0));
	float3   t_scatter_position    = mul(t_aperture_transform, float4(scatter.position, 1)).xyz;
	float2   t_die_projection      = abs(t_aperture.size * t_scatter_position.xy);
	float    t_scatter_dist_square = dot(t_scatter_position, t_scatter_position);
	float    t_t0                  = sqrt(t_scatter_dist_square) / settings.speedOfSound;
	float    t_dt1                 = t_t0 * min(t_die_projection.x, t_die_projection.y) / t_scatter_dist_square;
	float    t_dt2                 = t_t0 * max(t_die_projection.x, t_die_projection.y) / t_scatter_dist_square;

	float4   t_rect_times   = t_t0 + 0.5f * (t_dt1 * float4(-1, +1, -1, +1) + t_dt2 * float4(-1, -1, +1, +1));
	float4   t_rect_samples = t_rect_times * fs;

	float t_denom = settings.cumulative ? aperture_power_denominator_cumulative(t_rect_samples, dt, t_dt2)
	                                    : aperture_power_denominator(t_rect_samples, dt, t_dt2);
	float t_scale = sqrt(scatter.amplitude) * t_aperture.apodization * t_aperture.size.x * t_aperture.size.y
	                / (2 * PI * sqrt(t_scatter_dist_square) * t_denom);

	// NOTE(rnp): receive relative values
	float4x4 r_aperture_transform = mul(rotate(r_aperture.normal, float3(0, 0, 1)),
	                                    translate(r_aperture.position, 0));
	float3   r_scatter_position    = mul(r_aperture_transform, float4(scatter.position, 1)).xyz;
	float2   r_die_projection      = abs(r_aperture.size * r_scatter_position.xy);
	float    r_scatter_dist_square = dot(r_scatter_position, r_scatter_position);
	float    r_t0                  = sqrt(r_scatter_dist_square) / settings.speedOfSound;
	float    r_dt1                 = r_t0 * min(r_die_projection.x, r_die_projection.y) / r_scatter_dist_square;
	float    r_dt2                 = r_t0 * max(r_die_projection.x, r_die_projection.y) / r_scatter_dist_square;

	float4   r_rect_times   = r_t0 + 0.5f * (r_dt1 * float4(-1, +1, -1, +1) + r_dt2 * float4(-1, -1, +1, +1));
	float4   r_rect_samples = (r_rect_times - settings.startTime) * fs;

	float r_denom = settings.cumulative ? aperture_power_denominator_cumulative(r_rect_samples, dt, r_dt2)
	                                    : aperture_power_denominator(r_rect_samples, dt, r_dt2);
	float r_scale = sqrt(scatter.amplitude) * r_aperture.apodization * r_aperture.size.x * r_aperture.size.y
	                / (2 * PI * sqrt(r_scatter_dist_square) * r_denom);

	uint t_out_index = scatter_index * settings.transmitCount + transmit_index;
	uint r_out_index = settings.scatterBatchCount * settings.transmitCount + scatter_index * settings.receiveCount + receive_index;
	packed_scatter_rects[t_out_index]  = t_rect_samples;
	packed_scatter_rects[r_out_index]  = r_rect_samples;
	packed_scatter_scales[t_out_index] = t_scale;
	packed_scatter_scales[r_out_index] = r_scale;
}
