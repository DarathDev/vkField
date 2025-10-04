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
	bool qDelta = rectSamples.w == rectSamples.x;
	bool qRect = !qDelta && (rectSamples.x == rectSamples.y);
	bool qTri = !qDelta && (rectSamples.x == rectSamples.y);
	bool qTrap = !(qDelta | qRect | qTri);

	bool qRectLeft = (n >= rectSamples.y - 0.5) & (n <= rectSamples.y + 0.5);
	bool qRectCenter = (n > rectSamples.y + 0.5) & (n <= rectSamples.z - 0.5);
	bool qRectRight = (n > rectSamples.z - 0.5) & (n <= rectSamples.z + 0.5);

	bool qTriLeft = (n >= rectSamples.x) & (n <= rectSamples.y);
	bool qTriRight = (n > rectSamples.z) & (n <= rectSamples.w);

	bool qTrapLeft = qTriLeft;
	bool qTrapCenter = (n > rectSamples.y) & (n <= rectSamples.z);
	bool qTrapRight = qTriRight;

	float sDelta = 1 - abs(n - rectSamples.x);

	float sRectLeft = n - (rectSamples.y - 0.5);
	float sRectCenter = 1;
	float sRectRight = 1 - (n - (rectSamples.z - 0.5));

	float sTriLeft = (n - rectSamples.x) / (rectSamples.y - rectSamples.x + EPSILON);
	float sTriRight = (1 - ((n - rectSamples.z) / (rectSamples.w - rectSamples.z + EPSILON)));

	float sTrapLeft = sTriLeft;
	float sTrapCenter = sRectCenter;
	float sTrapRight = sTriRight;

	float value = qDelta*sDelta 
		+ qRect*(qRectLeft*sRectLeft + qRectCenter*sRectCenter + qRectRight*sRectRight)
		+ qTri*(qTriLeft*sTriLeft + qTriRight*sTriRight)
		+ qTrap*(qTrapLeft*sTrapLeft + qTrapCenter*sTrapCenter + qTrapRight*sTrapRight);
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
	

	RectangularAperture transmitAperture = transmitApertures[transmitIndex];
	RectangularAperture receiveAperture = receiveApertures[settings.receiveIndex];

	float time = startingTime + n / samplingFrequency;

	time += transmitAperture.delay + receiveAperture.delay;

	float2 aperWidthT = transmitAperture.size;
	float4x4 apertureTransformT = mul(rotate(transmitAperture.normal, float3(0, 0, 1)), translate(transmitAperture.position, 0));
	float3 scatterPositionT = mul(apertureTransformT, float4(scatterPosition, 1)).xyz;

	float2 aperWidthR = receiveAperture.size;
	float4x4 apertureTransformR = mul(rotate(receiveAperture.normal, float3(0, 0, 1)), translate(receiveAperture.position, 0));
	float3 scatterPositionR = mul(apertureTransformR, float4(scatterPosition, 1)).xyz;

	float2 dieProjectionT = aperWidthT * scatterPositionT.xy;
	float t0T = length(scatterPositionT) / speedOfSound; float t0T10 = t0T*1e3;
	float dt1T = min(abs(dieProjectionT.x), abs(dieProjectionT.y)) * t0T / dot(scatterPositionT, scatterPositionT);
	float dt2T = max(abs(dieProjectionT.x), abs(dieProjectionT.y)) * t0T / dot(scatterPositionT, scatterPositionT);
	float4 tRectT = t0T + 0.5 * (dt1T * float4(-1, +1, -1, +1) + dt2T * float4(-1, -1, +1, +1));
	float4 nRectT = tRectT*samplingFrequency;

	float2 dieProjectionR = aperWidthR * scatterPositionR.xy;
	float t0R = length(scatterPositionR) / speedOfSound; float t0R10 = t0R*1e3;
	float dt1R = min(abs(dieProjectionR.x), abs(dieProjectionR.y)) * t0R / dot(scatterPositionR, scatterPositionR);
	float dt2R = max(abs(dieProjectionR.x), abs(dieProjectionR.y)) * t0R / dot(scatterPositionR, scatterPositionR);
	float4 tRectR = t0R + 0.5 * (dt1R * float4(-1, +1, -1, +1) + dt2R * float4(-1, -1, +1, +1));
	tRectR -= startingTime;
	float4 nRectR = tRectR*samplingFrequency;

	int minN = int(floor(nRectT.x) + floor(nRectR.x)); // unneeded calculation
	int maxN = int(ceil(nRectT.w) + ceil(nRectR.w)); // unneeded calculation

	int minK = int(max(floor(nRectT.x - 0.5f), n - ceil(nRectR.w - 0.5f)));
	int maxK = int(min(ceil(nRectT.w + 0.5f), n - floor(nRectR.x + 0.5f)));

	float powerT = (dot(aperWidthT, 1))/(2*pi*length(scatterPositionT))/(tRectT.x == tRectT.w ? 1 : tRectT.w - tRectT.x);
	float powerR = (dot(aperWidthR, 1))/(2*pi*length(scatterPositionR))/(tRectR.x == tRectR.w ? 1 : tRectR.w - tRectR.x);

	float sum = 0;
	
	
	for (int i = minK; i <= maxK; i++) {
		float vT = sample_rect_aperture(i, nRectT);
		float vR = sample_rect_aperture(n - i, nRectR);
		sum += vT * vR;
	}
	sum *= powerT*powerR*scatter.amplitude*transmitAperture.apodization*receiveAperture.apodization; // TODO: Add Apodization

	response[storeOffset + n] = sum;
}
