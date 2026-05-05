module packSpatialImpulseResponse;

import util;

layout(constant_id =  0)  const uint  WorkgroupSizeX    = 4;
layout(constant_id =  1)  const uint  WorkgroupSizeY    = 4;
layout(constant_id =  2)  const uint  WorkgroupSizeZ    = 4;

layout(constant_id =  3)  const uint  TransmitCount     = 0;
layout(constant_id =  4)  const uint  ReceiveCount      = 0;
layout(constant_id =  5)  const uint  ScatterCount      = 0;
layout(constant_id =  6)  const uint  ReceiveBatchCount = 0;
layout(constant_id =  7)  const uint  ScatterBatchCount = 0;
layout(constant_id =  8)  const bool  Cumulative        = false;
layout(constant_id =  9)  const float StartTime         = 0;
layout(constant_id =  10) const float SamplingFrequency = 0;
layout(constant_id =  11) const float SpeedOfSound      = 0;

public struct Scatter {
  public float3 position;
  public float amplitude;
};

struct PackSirSettings {
	void* elements;
	Scatter* scatters;
	float4* spatialImpulseResponses;
	uint scatterBatchOffset;
	uint receiveBatchOffset;

};

[[vk::push_constant]]
ConstantBuffer<PackSirSettings> settings;

float aperture_power_denominator(in float4 rect_samples, in float dt, in float dt2)
{
  return rect_samples.w - rect_samples.x <= 1 ? dt : dt2;
}

[shader("compute")]
[numthreads(WorkgroupSizeX, WorkgroupSizeY, WorkgroupSizeZ)]
void main(uint3 GlobalInvocationID: SV_DispatchThreadID)
{
	uint scatter_index  = GlobalInvocationID.x;
	uint receive_base_index  = GlobalInvocationID.y;
	uint transmit_index = GlobalInvocationID.z;
	uint receive_index = receive_base_index + settings.receiveBatchOffset;


	uint3 dispatch_test = uint3(ScatterBatchCount, ReceiveBatchCount, TransmitCount);
	if (any(GlobalInvocationID >= dispatch_test))
		return;

	void *elements = settings.elements;
	int elementCount = TransmitCount + ReceiveCount;
	float3 tPosition = ((float3 *)elements)[transmit_index];
	float3 rPosition = ((float3 *)elements)[TransmitCount + receive_index];
	elements = (void *)&((float3 *)elements)[elementCount];
	float3 tNormal = ((float3 *)elements)[transmit_index];
	float3 rNormal = ((float3 *)elements)[TransmitCount + receive_index];
	elements = (void *)&((float3 *)elements)[elementCount];
	float2 tSize = ((float2 *)elements)[transmit_index];
	float2 rSize = ((float2 *)elements)[TransmitCount + receive_index];
	elements = (void *)&((float2 *)elements)[elementCount];
	float tApodization = ((float *)elements)[transmit_index];
	float rApodization = ((float *)elements)[TransmitCount + receive_index];
	elements = (void *)&((float *)elements)[elementCount];
	float tDelay = ((float *)elements)[transmit_index];
	float rDelay = ((float *)elements)[TransmitCount + receive_index];
	elements = (void *)&((float *)elements)[elementCount];

	Scatter             scatter    = settings.scatters[settings.scatterBatchOffset + scatter_index];

	float fs = SamplingFrequency;
	float dt = 1.f / fs;

	float4x4 t_aperture_transform = mul(rotate(tNormal, float3(0, 0, 1)),
	                                    translate(tPosition, 0));
	float3   t_scatter_position    = mul(t_aperture_transform, float4(scatter.position, 1)).xyz;
	float2   t_die_projection      = abs(tSize * t_scatter_position.xy);
	float    t_scatter_dist_square = dot(t_scatter_position, t_scatter_position);
	float    t_t0                  = sqrt(t_scatter_dist_square) / SpeedOfSound;
	float    t_dt1                 = t_t0 * min(t_die_projection.x, t_die_projection.y) / t_scatter_dist_square;
	float    t_dt2                 = t_t0 * max(t_die_projection.x, t_die_projection.y) / t_scatter_dist_square;

	float4   t_rect_times   = t_t0 + 0.5f * (t_dt1 * float4(-1, +1, -1, +1) + t_dt2 * float4(-1, -1, +1, +1));
	float4   t_rect_samples = t_rect_times * fs;

	float t_denom = aperture_power_denominator(t_rect_samples, dt, t_dt2);
	float t_scale = sqrt(scatter.amplitude) * tApodization * tSize.x * tSize.y
	                / (2 * PI * sqrt(t_scatter_dist_square) * t_denom);

	float4x4 r_aperture_transform = mul(rotate(rNormal, float3(0, 0, 1)),
	                                    translate(rPosition, 0));
	float3   r_scatter_position    = mul(r_aperture_transform, float4(scatter.position, 1)).xyz;
	float2   r_die_projection      = abs(rSize * r_scatter_position.xy);
	float    r_scatter_dist_square = dot(r_scatter_position, r_scatter_position);
	float    r_t0                  = sqrt(r_scatter_dist_square) / SpeedOfSound;
	float    r_dt1                 = r_t0 * min(r_die_projection.x, r_die_projection.y) / r_scatter_dist_square;
	float    r_dt2                 = r_t0 * max(r_die_projection.x, r_die_projection.y) / r_scatter_dist_square;

	float4   r_rect_times   = r_t0 + 0.5f * (r_dt1 * float4(-1, +1, -1, +1) + r_dt2 * float4(-1, -1, +1, +1));
	float4   r_rect_samples = (r_rect_times - StartTime) * fs;

	float r_denom = aperture_power_denominator(r_rect_samples, dt, r_dt2);
	float r_scale = sqrt(scatter.amplitude) * rApodization * rSize.x * rSize.y
	                / (2 * PI * sqrt(r_scatter_dist_square) * r_denom);

	uint t_out_index = scatter_index * TransmitCount + transmit_index;
	uint r_out_index = ScatterBatchCount * TransmitCount + scatter_index * ReceiveBatchCount + receive_base_index;

	float4 *sirRects = settings.spatialImpulseResponses;
	float *sirScales = Ptr<float>(sirRects + (ScatterBatchCount * (TransmitCount + ReceiveBatchCount)));

	sirRects[t_out_index]  = t_rect_samples;
	sirRects[r_out_index]  = r_rect_samples;
	sirScales[t_out_index] = t_scale;
	sirScales[r_out_index] = r_scale;
}
