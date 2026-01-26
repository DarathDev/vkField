#define VULKAN 100
#define EPSILON 0.0001
#define PI 3.14159265358979323846264338327950288

struct SimulationSettings {
	float samplingFrequency;
	float speedOfSound;
	float startingTime;
	uint sampleCount;
	uint receiveIndex;
};

struct RectangularAperture {
	float3 position;
	uint padding0;
	float3 normal;
	uint padding1;
	float2 size;
	uint2 padding2;
	uint apertureType;
	float apodization;
	float delay;
	bool active;
	uint padding3;
};

struct Scatter {
	float3 position;
	float amplitude;
};

#if defined(_DXC)
[[vk::push_constant]]
SimulationSettings settings;
#else
[[vk::push_constant]]
ConstantBuffer<SimulationSettings> settings;
#endif

[[vk::binding(0, 0)]]
RWStructuredBuffer<RectangularAperture> transmitApertures : register(b0, space0);

[[vk::binding(1, 0)]]
RWStructuredBuffer<RectangularAperture> receiveApertures : register(b1, space0);

[[vk::binding(2, 0)]]
RWStructuredBuffer<Scatter> scatters : register(b2, space0);

[[vk::binding(3, 0)]]
RWBuffer<float> response : register(b3, space0);

float sample_rect_aperture(in float n, in float4 rectSamples) {
	bool qDelta = rectSamples.w - rectSamples.x < 1;
	bool qRect  = !qDelta && (rectSamples.y - rectSamples.x < 1);
	bool qTri   = !qDelta && (rectSamples.z - rectSamples.y < 1);
	bool qTrap  = !(qDelta | qRect | qTri);

	bool qRectLeft   = (n >= rectSamples.y - 0.5f) & (n <= rectSamples.y + 0.5f);
	bool qRectCenter = (n > rectSamples.y + 0.5f)  & (n <= rectSamples.z - 0.5f);
	bool qRectRight  = (n > rectSamples.z - 0.5f)  & (n <= rectSamples.z + 0.5f);

	bool qTriLeft  = (n >= rectSamples.x) & (n <= rectSamples.y);
	bool qTriRight = (n > rectSamples.z)  & (n <= rectSamples.w);

	bool qTrapLeft   = qTriLeft;
	bool qTrapCenter = (n > rectSamples.y) & (n <= rectSamples.z);
	bool qTrapRight  = qTriRight;


	float sDelta = 1.f - abs(n - rectSamples.x);

	float sRectLeft   = n - (rectSamples.y - 0.5f);
	float sRectCenter = 1.f;
	float sRectRight  = 1.f - (n - (rectSamples.z - 0.5f));

	float sTriLeft  =  (n - rectSamples.x) / (rectSamples.y - rectSamples.x + EPSILON);
	float sTriRight =  (1.f - (n - rectSamples.z) / (rectSamples.w - rectSamples.z + EPSILON));

	float sTrapLeft   = sTriLeft;
	float sTrapCenter = sRectCenter;
	float sTrapRight  = sTriRight;

	float value = qDelta * sDelta
		+ qRect * ((qRectLeft * sRectLeft) + (qRectCenter * sRectCenter) + (qRectRight * sRectRight))
		+ qTri  * ((qTriLeft * sTriLeft) + (qTriRight * sTriRight))
		+ qTrap * ((qTrapLeft * sTrapLeft) + (qTrapCenter * sTrapCenter) + (qTrapRight * sTrapRight));
	return saturate(value);
}

float4x4 translate(in float3 from, in float3 to) {
	return float4x4(
		1, 0, 0, to.x - from.x,
		0, 1, 0, to.y - from.y,
		0, 0, 1, to.z - from.z,
		0, 0, 0, 1
	);
}

float4x4 rotate(in float3 from, in float3 to) {
	float3 axis = cross(from, to);
	float theta = acos(dot(from, to));
	float4x4 eye = {
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1,
	};
	float4x4 a = {
		0, -axis.z, axis.y, 0,
		axis.z, 0, -axis.x, 0,
		-axis.y, axis.x, 0, 0,
		0, 0, 0, 1,
	};
	return eye + sin(theta)*a + (1-cos(theta))*mul(a, a);
}

[numthreads(128, 1, 1)]
void main(uint3 GlobalInvocationID : SV_DISPATCHTHREADID) {
	int n = GlobalInvocationID.x;
	uint transmitIndex = GlobalInvocationID.y;
	uint scatterIndex = GlobalInvocationID.z;
	Scatter scatter = scatters[scatterIndex];
	float3 scatterPosition = scatter.position;
	if (n >= settings.sampleCount) {
		return;
	}
	uint storeOffset = settings.receiveIndex*settings.sampleCount;

	float startingTime = settings.startingTime;
	float samplingFrequency = settings.samplingFrequency;
	float speedOfSound = settings.speedOfSound;
	float pi = PI;
	float dt = 1.f/samplingFrequency;

	RectangularAperture transmitAperture = transmitApertures[transmitIndex];
	RectangularAperture receiveAperture = receiveApertures[settings.receiveIndex];

	float time = startingTime + n * dt;
	time += transmitAperture.delay + receiveAperture.delay;

	float2 apertureSizeT = transmitAperture.size;
	float4x4 apertureTransformT = mul(rotate(transmitAperture.normal, float3(0, 0, 1)), translate(transmitAperture.position, 0));
	float3 scatterPositionT = mul(apertureTransformT, float4(scatterPosition, 1)).xyz;
	float2 dieProjectionT = abs(apertureSizeT * scatterPositionT.xy);

	float2 apertureSizeR = receiveAperture.size;
	float4x4 apertureTransformR = mul(rotate(receiveAperture.normal, float3(0, 0, 1)), translate(receiveAperture.position, 0));
	float3 scatterPositionR = mul(apertureTransformR, float4(scatterPosition, 1)).xyz;
	float2 dieProjectionR = abs(apertureSizeR * scatterPositionR.xy);

	float t0T = length(scatterPositionT) / speedOfSound;
	float dt1T = min(dieProjectionT.x, dieProjectionT.y) * t0T / dot(scatterPositionT, scatterPositionT);
	float dt2T = max(dieProjectionT.x, dieProjectionT.y) * t0T / dot(scatterPositionT, scatterPositionT);
	float4 tRectT = t0T + 0.5f * (dt1T * float4(-1, +1, -1, +1) + dt2T * float4(-1, -1, +1, +1));
	float4 nRectT = tRectT*samplingFrequency;

	float t0R = length(scatterPositionR) / speedOfSound;
	float dt1R = min(dieProjectionR.x, dieProjectionR.y) * t0R / dot(scatterPositionR, scatterPositionR);
	float dt2R = max(dieProjectionR.x, dieProjectionR.y) * t0R / dot(scatterPositionR, scatterPositionR);
	float4 tRectR = t0R + 0.5f * (dt1R * float4(-1, +1, -1, +1) + dt2R * float4(-1, -1, +1, +1));
	float4 nRectR = (tRectR - startingTime)*samplingFrequency;

	int minK = int(max(floor(nRectT.x - 0.5f), n - ceil(nRectR.w + 0.5f)));
	int maxK = int(min(ceil(nRectT.w + 0.5f), n - floor(nRectR.x - 0.5f)));

	float powerT = (apertureSizeT.x * apertureSizeT.y) / (2 * pi * length(scatterPositionT)) / (nRectT.w - nRectT.x <= 1 ? dt : dt2T);
	float powerR = (apertureSizeR.x * apertureSizeR.y) / (2 * pi * length(scatterPositionR)) / (nRectR.w - nRectR.x <= 1 ? dt : dt2R);

	float sum = 0;
	for (int i = minK; i <= maxK; i++) {
		float vT = sample_rect_aperture(i, nRectT);
		float vR = sample_rect_aperture(n - i, nRectR);
		sum += vT * vR;
	}
	sum *= powerT*powerR*scatter.amplitude*transmitAperture.apodization*receiveAperture.apodization;

	response[storeOffset + n] = sum;
}
