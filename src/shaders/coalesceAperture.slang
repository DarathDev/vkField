module coalesceAperture;

import util;
import coalesceUtil;

[vk::constant_id(12)]
const uint SampleWorkgroupSize = 64;
[vk::constant_id(13)]
const uint ElementSetWorkgroupSize = 1;
[vk::constant_id(14)]
const uint ScattererWorkgroupSize = 1;

[shader("compute")]
[numthreads(SampleWorkgroupSize, ElementSetWorkgroupSize, ScattererWorkgroupSize)]
void main(uint3 GlobalInvocationID: SV_DispatchThreadID) {
  uint sampleIndex = GlobalInvocationID.x + pushData.sampleOffset;
  uint elementSetIndex = GlobalInvocationID.y + pushData.elementSetOffset;
  uint scattererIndex = GlobalInvocationID.z;

  uint ElementSetCount = CoalesceTransmissions ? TransmissionCount : ReceiveChannelCount;

  uint3 dispatchTest = uint3(ApertureSampleCount, ElementSetCount, ScattererCount - pushData.scattererOffset);
  if (any(GlobalInvocationID >= dispatchTest))
    return;

  uint elementSetInfoIndex = scattererIndex * ElementSetCount + elementSetIndex;
  ElementSetInfo elementSetInfo =
      CoalesceTransmissions ? pushData.transmissionInfos[elementSetInfoIndex] : pushData.getReceiveChannelInfos()[elementSetInfoIndex];

  uint sampleOutputIndex = scattererIndex * (ApertureSampleCount * ElementSetCount) + elementSetIndex * ApertureSampleCount + sampleIndex;
  int supportSampleCount = elementSetInfo.maxSample - elementSetInfo.minSample;
  if (elementSetInfo.minSample > elementSetInfo.maxSample || sampleIndex > uint(min(int(ApertureSampleCount) - 1, supportSampleCount))) {
    if (CoalesceTransmissions) {
      pushData.transmissionResponses[sampleOutputIndex] = 0;
    } else {
      pushData.getReceiveChannelResponses()[sampleOutputIndex] = 0;
    }
    return;
  }

  float dt = 1.f / SamplingFrequency;
  // We need to offset by the start time once
  float timeOffset = CoalesceTransmissions ? 0 : -StartTime;

  float sampleSum = 0;
  uint memberCount = pushData.getMemberCount(elementSetIndex);
  for (uint memberIndex = 0; memberIndex < memberCount; memberIndex++) {
    SetMember member = pushData.getSetMember(elementSetIndex, memberIndex);

    ApertureResponse memberResponse = getResponse(member, scattererIndex, dt);
    if (memberResponse.scale == 0)
      continue;

    memberResponse.rectTimes += timeOffset;

    float4 rectSamples = memberResponse.rectTimes * SamplingFrequency - elementSetInfo.minSample;

    float sample = sample_rect_aperture(sampleIndex, rectSamples);
    sampleSum += sample * memberResponse.scale;
  }

  if (CoalesceTransmissions) {
    pushData.transmissionResponses[sampleOutputIndex] = sampleSum;
  } else {
    pushData.getReceiveChannelResponses()[sampleOutputIndex] = sampleSum;
  }
}

float sample_rect_aperture(in int i, in float4 nRectT) {
  if (Cumulative) {
    return sample_rect_aperture_cumulative(i, nRectT) - sample_rect_aperture_cumulative(i - 1, nRectT);
  } else {
    return sample_rect_aperture_discrete(i, nRectT);
  }
}

float b2f(bool v) { return v ? 1.0f : 0.0f; }

float sample_rect_aperture_cumulative(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.w - rectSamples.x <= 1.f;
  bool qRect = !qDelta && (rectSamples.y - rectSamples.x <= EPSILON);
  bool qTri = !qDelta && !qRect && (rectSamples.z - rectSamples.y <= EPSILON);
  bool qTrap = !(qDelta | qRect | qTri);

  float sDelta = n >= rectSamples.x ? 1 : 0;

  float dy = rectSamples.z - rectSamples.y;
  float sRect = dy <= 0.f ? 0.0f : dy * saturate((n - rectSamples.y) / dy);

  float dxLeft = rectSamples.y - rectSamples.x;
  float sTriLeftSat = dxLeft <= 0.f ? 0.0f : saturate((n - rectSamples.x) / dxLeft);
  float sTriLeft = 0.5f * dxLeft * sTriLeftSat * sTriLeftSat;

  float dxRight = rectSamples.w - rectSamples.z;
  float sTriRightSat = dxRight <= 0.f ? 0.0f : saturate((rectSamples.w - n) / dxRight);
  float sTriRight = 0.5f * dxRight * (1.f - sTriRightSat * sTriRightSat);

  float value =
      b2f(qDelta) * sDelta + b2f(qRect) * sRect + b2f(qTri) * (sTriLeft + sTriRight) + b2f(qTrap) * (sTriLeft + sRect + sTriRight);
  return value;
}

float sample_rect_aperture_discrete(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.w - rectSamples.x <= 1.f;
  bool qRect = !qDelta && (rectSamples.y - rectSamples.x <= EPSILON);
  bool qTri = !qDelta && !qRect && (rectSamples.z - rectSamples.y <= EPSILON);
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

  float value = b2f(qDelta) * sDelta +
                b2f(qRect) * ((b2f(qRectLeft) * sRectLeft) + (b2f(qRectCenter) * sRectCenter) + (b2f(qRectRight) * sRectRight)) + //
                b2f(qTri) * ((b2f(qTriLeft) * sTriLeft) + (b2f(qTriRight) * sTriRight)) +                                         //
                b2f(qTrap) * ((b2f(qTrapLeft) * sTrapLeft) + (b2f(qTrapCenter) * sTrapCenter) + (b2f(qTrapRight) * sTrapRight));
  return saturate(value);
}
