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

struct ApertureResponse {
	float4 rectSamples;
	float scale;
};

[[vk::push_constant]]
ConstantBuffer<PackSirSettings> settings;

ApertureResponse compute_aperture_response(
	in float3 position, in float3 normal, in float2 size, in float apodization,
	in Scatter scatter,
	in float fs, in float dt, in float start_time) {

	float4x4 apertureTransform = mul(rotate(normal, float3(0, 0, 1)), translate(position, 0));
	float3 scatterRelativePosition = mul(apertureTransform, float4(scatter.position, 1)).xyz;
	float2 dieProjection = abs(size * scatterRelativePosition.xy);
	float distance = sqrt(dot(scatterRelativePosition, scatterRelativePosition));
	float t0 = distance / SpeedOfSound;
	float dt1 = min(dieProjection.x, dieProjection.y) / distance / SpeedOfSound;
	float dt2 = max(dieProjection.x, dieProjection.y) / distance / SpeedOfSound;

	ApertureResponse response;

	float4 rectTimes = t0 + 0.5f * (dt1 * float4(-1, +1, -1, +1) + dt2 * float4(-1, -1, +1, +1));
	response.rectSamples = (rectTimes - start_time) * fs;

	float denom = response.rectSamples.w - response.rectSamples.x <= 1 ? dt : dt2;
	response.scale = sqrt(scatter.amplitude) * apodization * size.x * size.y
	               / (2 * PI * distance * denom);
	return response;
}

[shader("compute")]
[numthreads(WorkgroupSizeX, WorkgroupSizeY, WorkgroupSizeZ)]
void main(uint3 GlobalInvocationID: SV_DispatchThreadID) {
	uint scatter_index = GlobalInvocationID.x;
	uint receive_base_index = GlobalInvocationID.y;
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

	Scatter scatter = settings.scatters[settings.scatterBatchOffset + scatter_index];

	float fs = SamplingFrequency;
	float dt = 1.f / fs;

	ApertureResponse transmitResponse = compute_aperture_response(
		tPosition, tNormal, tSize, tApodization,
		scatter, fs, dt, 0);
	ApertureResponse receiveResponse = compute_aperture_response(
		rPosition, rNormal, rSize, rApodization,
		scatter, fs, dt, StartTime);

	uint transmitOutIndex = scatter_index * TransmitCount + transmit_index;
	uint receiveOutIndex = ScatterBatchCount * TransmitCount + scatter_index * ReceiveBatchCount + receive_base_index;

	float4 *sirRects = settings.spatialImpulseResponses;
	float *sirScales = Ptr<float>(sirRects + (ScatterBatchCount * (TransmitCount + ReceiveBatchCount)));

	sirRects[transmitOutIndex] = transmitResponse.rectSamples;
	sirRects[receiveOutIndex] = receiveResponse.rectSamples;
	sirScales[transmitOutIndex] = transmitResponse.scale;
	sirScales[receiveOutIndex] = receiveResponse.scale;
}
