module coalesceUtil;

import util;

[vk::constant_id(10)]
public const bool CoalesceTransmissions = true;
[vk::constant_id(11)]
public const bool Cumulative = false;

public struct CoalesceAperturePushData {
  public float4 *apertureResponseRects;
  public ElementSetInfo *transmissionInfos;
  public float *transmissionResponses;
  public uint *transmissionElementCounts;
  public uint *elementSetMembers;
  public uint elementSetOffset;
  public uint sampleOffset;
  public uint scattererOffset;

  public float *getApertureResponseScales() {
    return (float *)((uint64_t)apertureResponseRects + (uint64_t)(ElementCount * ScattererBatchCount) * sizeof(float4));
  }

  public ElementSetInfo *getReceiveChannelInfos() {
    return (ElementSetInfo *)((uint64_t)transmissionInfos + (uint64_t)(TransmissionCount * ScattererBatchCount) * sizeof(ElementSetInfo));
  }

  public float *getReceiveChannelResponses() {
    return (float *)((uint64_t)transmissionResponses +
                     (uint64_t)(TransmissionCount * ScattererBatchCount * ApertureSampleCount) * sizeof(float));
  }

  public uint *getTransmissionBaseOffsets() {
    return (uint *)((uint64_t)transmissionElementCounts + (uint64_t)TransmissionCount * sizeof(uint));
  }

  public uint *getReceiveChannelElementCounts() {
    return (uint *)((uint64_t)getTransmissionBaseOffsets() + (uint64_t)TransmissionCount * sizeof(uint));
  }

  public uint *getReceiveChannelBaseOffsets() {
    return (uint *)((uint64_t)getReceiveChannelElementCounts() + (uint64_t)ReceiveChannelCount * sizeof(uint));
  }

  public uint getMemberCount(uint elementSetIndex) {
    if (CoalesceTransmissions) {
      return transmissionElementCounts[elementSetIndex];
    } else {
      return getReceiveChannelElementCounts()[elementSetIndex];
    }
  }

  public SetMember getSetMember(uint elementSetIndex, uint memberIndex) {
    uint baseOffset;
    if (CoalesceTransmissions) {
      baseOffset = getTransmissionBaseOffsets()[elementSetIndex];
    } else {
      baseOffset = getReceiveChannelBaseOffsets()[elementSetIndex];
    }
    uint memberCount = getMemberCount(elementSetIndex);
    SetMember member;
    member.index = elementSetMembers[baseOffset + memberIndex];
    member.apodization = ((float *)elementSetMembers)[baseOffset + memberCount + memberIndex];
    member.delay = ((float *)elementSetMembers)[baseOffset + 2 * memberCount + memberIndex];
    return member;
  }
}

[[vk::push_constant]]
public ConstantBuffer<CoalesceAperturePushData> pushData;

public ApertureResponse getResponse(SetMember member, uint scattererIndex, float dt) {
  ApertureResponse memberResponse;
  uint responseIndex = scattererIndex * ElementCount + member.index;
  memberResponse.rectTimes = pushData.apertureResponseRects[responseIndex];
  memberResponse.scale = pushData.getApertureResponseScales()[responseIndex];
  memberResponse.rectTimes += member.delay;
  if (!CoalesceTransmissions) {
    if (Cumulative) {
      memberResponse.rectTimes -= dt;
    }
  }
  memberResponse.scale *= member.apodization;
  return memberResponse;
}

