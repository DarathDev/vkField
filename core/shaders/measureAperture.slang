module measureApertureResponses;

import util;
import coalesceUtil;

[vk::constant_id(12)]
const uint ElementSetWorkgroupSize = 1;
[vk::constant_id(13)]
const uint ScattererWorkgroupSize = 64;

[shader("compute")]
[numthreads(ElementSetWorkgroupSize, ScattererWorkgroupSize, 1)]
void main(uint2 GlobalInvocationID: SV_DispatchThreadID) {
  uint elementSetIndex = GlobalInvocationID.x;
  uint scattererIndex = GlobalInvocationID.y;

  uint ElementSetCount = CoalesceTransmissions ? TransmissionCount : ReceiveChannelCount;

  uint2 dispatchTest = uint2(ElementSetCount, min(ScattererBatchCount, ScattererCount - pushData.scattererOffset));
  if (any(GlobalInvocationID >= dispatchTest))
    return;

  float dt = 1.f / SamplingFrequency;
  // We need to offset by the start time once
  float timeOffset = CoalesceTransmissions ? 0 : -StartTime;

  ElementSetInfo elementSetInfo;
  elementSetInfo.minSample = MAX_INT;
  elementSetInfo.maxSample = MIN_INT;
  uint memberCount = pushData.getMemberCount(elementSetIndex);
  for (uint memberIndex = 0; memberIndex < memberCount; memberIndex++) {
    SetMember member = pushData.getSetMember(elementSetIndex, memberIndex);

    ApertureResponse memberResponse = getResponse(member, scattererIndex, dt);
    if (memberResponse.scale == 0)
      continue;

    memberResponse.rectTimes += timeOffset;

    elementSetInfo.minSample = min(elementSetInfo.minSample, int(floor((memberResponse.rectTimes.x * SamplingFrequency) - 0.5)));
    elementSetInfo.maxSample = max(elementSetInfo.maxSample, int(ceil((memberResponse.rectTimes.w * SamplingFrequency) + 0.5)));
  }

  uint outputIndex = scattererIndex * ElementSetCount + elementSetIndex;
  if (CoalesceTransmissions) {
    pushData.transmissionInfos[outputIndex] = elementSetInfo;
  } else {
    pushData.getReceiveChannelInfos()[outputIndex] = elementSetInfo;
  }
}
