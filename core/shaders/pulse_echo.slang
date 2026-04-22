module pulse_echo;

import pulse_echo_common;

float b2f(bool v) {
  return v ? 1.0f : 0.0f;
}

#if defined(PULSE_ECHO_CUMULATIVE)
float sample_rect_aperture_cumulative(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.x == rectSamples.w;
  bool qRect = !qDelta && (rectSamples.x == rectSamples.y);
  bool qTri = !qDelta && (rectSamples.y == rectSamples.z);
  bool qTrap = !(qDelta | qRect | qTri);

  float sDelta = n >= rectSamples.x ? 1 : 0;

  float sRect = (rectSamples.z - rectSamples.y) * saturate((n - rectSamples.y) / (rectSamples.z - rectSamples.y));

  float sTriLeftSat = saturate((n - rectSamples.x) / (rectSamples.y - rectSamples.x));
  float sTriLeft = 0.5f * (rectSamples.y - rectSamples.x) * sTriLeftSat * sTriLeftSat;
  float sTriRightSat = saturate((rectSamples.w - n) / (rectSamples.w - rectSamples.z));
  float sTriRight = 0.5f * (rectSamples.w - rectSamples.z) * (1 - sTriRightSat * sTriRightSat);

  float value = b2f(qDelta) * sDelta + b2f(qRect) * sRect + b2f(qTri) * (sTriLeft + sTriRight) + b2f(qTrap) * (sTriLeft + sRect + sTriRight);
  return value;
}

float aperture_power_denominator(in float4 nRect, in float dt, in float dt2) {
  return nRect.x == nRect.w ? dt : dt2;
}

float sample_transmit_aperture(in int i, in float4 nRectT) {
  return sample_rect_aperture_cumulative(i, nRectT) - sample_rect_aperture_cumulative(i - 1, nRectT);
}

float sample_receive_aperture(in int n, in int i, in float4 nRectR) {
  return sample_rect_aperture_cumulative(n - i + 1, nRectR) - sample_rect_aperture_cumulative(n - i, nRectR);
}
#else
float sample_rect_aperture_discrete(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.w - rectSamples.x < 1;
  bool qRect = !qDelta && (rectSamples.y - rectSamples.x < 1);
  bool qTri = !qDelta && (rectSamples.z - rectSamples.y < 1);
  bool qTrap = !(qDelta | qRect | qTri);

  bool qRectLeft = (n >= rectSamples.y - 0.5f) & (n <= rectSamples.y + 0.5f);
  bool qRectCenter = (n > rectSamples.y + 0.5f) & (n <= rectSamples.z - 0.5f);
  bool qRectRight = (n > rectSamples.z - 0.5f) & (n <= rectSamples.z + 0.5f);

  bool qTriLeft = (n >= rectSamples.x) & (n <= rectSamples.y);
  bool qTriRight = (n > rectSamples.z) & (n <= rectSamples.w);

  bool qTrapLeft = qTriLeft;
  bool qTrapCenter = (n > rectSamples.y) & (n <= rectSamples.z);
  bool qTrapRight = qTriRight;

  float sDelta = 1.f - abs(n - rectSamples.x);

  float sRectLeft = n - (rectSamples.y - 0.5f);
  float sRectCenter = 1.f;
  float sRectRight = 1.f - (n - (rectSamples.z - 0.5f));

  float sTriLeft = (n - rectSamples.x) / (rectSamples.y - rectSamples.x + EPSILON);
  float sTriRight = (1.f - (n - rectSamples.z) / (rectSamples.w - rectSamples.z + EPSILON));

  float sTrapLeft = sTriLeft;
  float sTrapCenter = sRectCenter;
  float sTrapRight = sTriRight;

  float value = b2f(qDelta) * sDelta + b2f(qRect) * ((b2f(qRectLeft) * sRectLeft) + (b2f(qRectCenter) * sRectCenter) + (b2f(qRectRight) * sRectRight)) + b2f(qTri) * ((b2f(qTriLeft) * sTriLeft) + (b2f(qTriRight) * sTriRight)) + b2f(qTrap) * ((b2f(qTrapLeft) * sTrapLeft) + (b2f(qTrapCenter) * sTrapCenter) + (b2f(qTrapRight) * sTrapRight));
  return saturate(value);
}

float aperture_power_denominator(in float4 nRect, in float dt, in float dt2) {
  return nRect.w - nRect.x <= 1 ? dt : dt2;
}

float sample_transmit_aperture(in int i, in float4 nRectT) {
  return sample_rect_aperture_discrete(i, nRectT);
}

float sample_receive_aperture(in int n, in int i, in float4 nRectR) {
  return sample_rect_aperture_discrete(n - i, nRectR);
}
#endif

[shader("compute")]
[numthreads(128, 1, 1)]
void main(uint3 GlobalInvocationID: SV_DispatchThreadID) {
  int n = GlobalInvocationID.x;
  uint transmitIndex = GlobalInvocationID.y;
  uint receiveIndex = GlobalInvocationID.z;
  uint scatterIndex = settings.scatterIndex;
  Scatter scatter = scatters[scatterIndex];
  float3 scatterPosition = scatter.position;
  if (n >= settings.sampleCount) {
    return;
  }
  uint storeOffset = receiveIndex * settings.sampleCount;

  float startingTime = settings.startingTime;
  float samplingFrequency = settings.samplingFrequency;
  float speedOfSound = settings.speedOfSound;
  float pi = PI;
  float dt = 1.f / samplingFrequency;

  RectangularAperture transmitAperture = transmitApertures[transmitIndex];
  RectangularAperture receiveAperture = receiveApertures[receiveIndex];

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
  float4 nRectT = tRectT * samplingFrequency;

  float t0R = length(scatterPositionR) / speedOfSound;
  float dt1R = min(dieProjectionR.x, dieProjectionR.y) * t0R / dot(scatterPositionR, scatterPositionR);
  float dt2R = max(dieProjectionR.x, dieProjectionR.y) * t0R / dot(scatterPositionR, scatterPositionR);
  float4 tRectR = t0R + 0.5f * (dt1R * float4(-1, +1, -1, +1) + dt2R * float4(-1, -1, +1, +1));
  float4 nRectR = (tRectR - startingTime) * samplingFrequency;

  int minK = int(max(floor(nRectT.x - 0.5f), n - ceil(nRectR.w + 0.5f)));
  int maxK = int(min(ceil(nRectT.w + 0.5f), n - floor(nRectR.x - 0.5f)));

  float powerT = (apertureSizeT.x * apertureSizeT.y) / (2 * pi * length(scatterPositionT)) / aperture_power_denominator(nRectT, dt, dt2T);
  float powerR = (apertureSizeR.x * apertureSizeR.y) / (2 * pi * length(scatterPositionR)) / aperture_power_denominator(nRectR, dt, dt2R);

  float sum = 0;
  for (int i = minK; i <= maxK; i++) {
    float vT = sample_transmit_aperture(i, nRectT);
    float vR = sample_receive_aperture(n, i, nRectR);
    sum += vT * vR;
  }
  sum *= powerT * powerR * scatter.amplitude * transmitAperture.apodization * receiveAperture.apodization;
  response[storeOffset + n].add(sum);
}
