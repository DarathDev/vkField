module pulseEchoConvolution;

import util;

[vk::constant_id(10)]
public const uint SampleWorkgroupSize = 64;

struct PulseEchoSettings {
  ElementSetInfo *transmissionInfos;
  float *transmissionResponses;
  float *response;
  uint transmissionIndex;
  uint receiveChannelIndex;
  uint scattererOffset;

  ElementSetInfo *getReceiveChannelInfos() {
    return (ElementSetInfo *)((uint64_t)transmissionInfos + (uint64_t)(TransmissionCount * ScattererBatchCount) * sizeof(ElementSetInfo));
  }

  float *getReceiveChannelResponses() {
    return (float *)((uint64_t)transmissionResponses +
                     (uint64_t)(TransmissionCount * ScattererBatchCount * ApertureSampleCount) * sizeof(float));
  }
};

[[vk::push_constant]]
ConstantBuffer<PulseEchoSettings> pushData;

groupshared float transmissionAperture[ApertureSampleCount];
groupshared float receiveChannelAperture[ApertureSampleCount];

[shader("compute")]
[numthreads(SampleWorkgroupSize, 1, 1)]
void main(uint ThreadID: SV_GroupIndex, uint1 LocalInvocationID: SV_GroupThreadID, uint1 GlobalInvocationID: SV_DispatchThreadID,
          uint1 GroupID: SV_GroupID) {

  const uint threadCount = SampleWorkgroupSize;

  uint sampleIndex = GlobalInvocationID.x;
  uint transmissionIndex = pushData.transmissionIndex;
  uint receiveChannelIndex = pushData.receiveChannelIndex;
  uint baseSampleIndex = GroupID * SampleWorkgroupSize;

  float sample = 0;
  for (uint scattererIndex = 0; scattererIndex < ScattererBatchCount; scattererIndex++) {
    if (scattererIndex + pushData.scattererOffset >= ScattererCount)
      break;

    GroupMemoryBarrierWithGroupSync();
    uint transmissionInputIndex = scattererIndex * TransmissionCount + transmissionIndex;
    uint receiveChannelInputIndex = scattererIndex * ReceiveChannelCount + receiveChannelIndex;
    ElementSetInfo transmissionInfo = pushData.transmissionInfos[transmissionInputIndex];
    ElementSetInfo receiveChannelInfo = pushData.getReceiveChannelInfos()[receiveChannelInputIndex];

    if (transmissionInfo.minSample > transmissionInfo.maxSample || receiveChannelInfo.minSample > receiveChannelInfo.maxSample)
      continue;

    // Check if there is actually contribution to the samples covered in this workgroup by the scatterer
    int minSample = clamp(transmissionInfo.minSample + receiveChannelInfo.minSample, 0, (int)ResponseSampleCount);
    int maxSample = clamp(transmissionInfo.maxSample + receiveChannelInfo.maxSample + 1, 0, (int)ResponseSampleCount);
    if (minSample >= maxSample || (int)baseSampleIndex > maxSample || (int)baseSampleIndex + (int)SampleWorkgroupSize < minSample)
      continue;

    // Load Impulse Responses
    {
      int nTotal = min(transmissionInfo.maxSample - transmissionInfo.minSample + 1, (int)ApertureSampleCount);
      if (nTotal <= 0)
        continue;
      uint nPerThread = (uint)nTotal / threadCount;
      uint nLeftover = (uint)nTotal % threadCount;
      uint nThisThread = nPerThread + uint(ThreadID < nLeftover);
      for (uint n = 0; n < nThisThread; n++) {
        uint apertureIndex = n * threadCount + ThreadID;
        uint sampleInputIndex =
            scattererIndex * (ApertureSampleCount * TransmissionCount) + transmissionIndex * ApertureSampleCount + apertureIndex;
        transmissionAperture[apertureIndex] = pushData.transmissionResponses[sampleInputIndex];
      }
    }
    {
      int nTotal = min(receiveChannelInfo.maxSample - receiveChannelInfo.minSample + 1, (int)ApertureSampleCount);
      if (nTotal <= 0)
        continue;
      uint nPerThread = (uint)nTotal / threadCount;
      uint nLeftover = (uint)nTotal % threadCount;
      uint nThisThread = nPerThread + uint(ThreadID < nLeftover);
      for (uint n = 0; n < nThisThread; n++) {
        uint apertureIndex = n * threadCount + ThreadID;
        uint sampleInputIndex =
            scattererIndex * (ApertureSampleCount * ReceiveChannelCount) + receiveChannelIndex * ApertureSampleCount + apertureIndex;
        receiveChannelAperture[apertureIndex] = pushData.getReceiveChannelResponses()[sampleInputIndex];
      }
    }
    GroupMemoryBarrierWithGroupSync();

    // Convolution
    int s = (int)sampleIndex - (transmissionInfo.minSample + receiveChannelInfo.minSample);
    int nTx = min(transmissionInfo.maxSample - transmissionInfo.minSample + 1, (int)ApertureSampleCount);
    int nRx = min(receiveChannelInfo.maxSample - receiveChannelInfo.minSample + 1, (int)ApertureSampleCount);

    for (int kt = 0; kt < nTx; kt++) {
      int kr = s - kt;
      if (kr >= 0 && kr < nRx) {
        sample += transmissionAperture[kt] * receiveChannelAperture[kr];
      }
    }
  }

  uint dataLineIndex = transmissionIndex * ReceiveChannelCount + receiveChannelIndex;
  pushData.response[dataLineIndex * ResponseSampleCount + sampleIndex] += sample;
}
