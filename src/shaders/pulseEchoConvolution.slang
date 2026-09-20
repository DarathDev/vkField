module pulseEchoConvolution;

import util;

[vk::constant_id(10)]
public const uint SampleWorkgroupSize = 64;
[vk::constant_id(11)]
public const uint ConvolutionTileSize = 256;

struct PulseEchoSettings {
  ElementSetInfo *transmissionInfos;
  float *transmissionResponses;
  float *response;
  uint pairOffset;
  uint sampleOffset;
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

groupshared float transmissionAperture[ConvolutionTileSize];
groupshared float receiveChannelAperture[ConvolutionTileSize + SampleWorkgroupSize - 1];

[shader("compute")]
[numthreads(SampleWorkgroupSize, 1, 1)]
void main(uint ThreadID: SV_GroupIndex, uint1 LocalInvocationID: SV_GroupThreadID, uint1 GlobalInvocationID: SV_DispatchThreadID,
          uint3 GroupID: SV_GroupID) {

  const uint threadCount = SampleWorkgroupSize;

  uint sampleIndex = GlobalInvocationID.x + pushData.sampleOffset;
  uint pairIndex = pushData.pairOffset + GroupID.y;
  if (pairIndex >= TransmissionCount * ReceiveChannelCount)
    return;

  uint transmissionIndex = pairIndex / ReceiveChannelCount;
  uint receiveChannelIndex = pairIndex % ReceiveChannelCount;
  uint baseSampleIndex = pushData.sampleOffset + GroupID.x * SampleWorkgroupSize;
  if (baseSampleIndex >= ResponseSampleCount)
    return;

  bool sampleInRange = sampleIndex < ResponseSampleCount;

  float sample = 0;
  for (uint scattererIndex = 0; scattererIndex < ScattererBatchCount; scattererIndex++) {
    if (scattererIndex + pushData.scattererOffset >= ScattererCount)
      break;

    GroupMemoryBarrierWithGroupSync();
    uint transmissionInputIndex = scattererIndex * TransmissionCount + transmissionIndex;
    uint receiveChannelInputIndex = scattererIndex * ReceiveChannelCount + receiveChannelIndex;
    ElementSetInfo transmissionInfo = pushData.transmissionInfos[transmissionInputIndex];
    ElementSetInfo receiveChannelInfo = pushData.getReceiveChannelInfos()[receiveChannelInputIndex];

    int nTx = clamp(transmissionInfo.maxSample - transmissionInfo.minSample + 1, 0, (int)ApertureSampleCount);
    int nRx = clamp(receiveChannelInfo.maxSample - receiveChannelInfo.minSample + 1, 0, (int)ApertureSampleCount);
    int outputMin = clamp(transmissionInfo.minSample + receiveChannelInfo.minSample, 0, (int)ResponseSampleCount);
    int outputMax = clamp(transmissionInfo.maxSample + receiveChannelInfo.maxSample + 1, 0, (int)ResponseSampleCount);
    bool contributes = nTx > 0 && nRx > 0 && outputMin < outputMax &&
                       (int)baseSampleIndex < outputMax && (int)baseSampleIndex + (int)SampleWorkgroupSize > outputMin;

    if (contributes) {
      int s = (int)sampleIndex - (transmissionInfo.minSample + receiveChannelInfo.minSample);
      int groupSMin = (int)baseSampleIndex - (transmissionInfo.minSample + receiveChannelInfo.minSample);
      int groupSMax = groupSMin + (int)SampleWorkgroupSize - 1;
      int txStart = max(0, groupSMin - (nRx - 1));
      int txEnd = min(nTx - 1, groupSMax);

      for (int tileStart = txStart; tileStart <= txEnd; tileStart += (int)ConvolutionTileSize) {
        int tileTxCount = min((int)ConvolutionTileSize, txEnd - tileStart + 1);
        int tileRxStart = max(0, groupSMin - (tileStart + tileTxCount - 1));
        int tileRxEnd = min(nRx - 1, groupSMax - tileStart);
        int tileRxCount = max(0, tileRxEnd - tileRxStart + 1);

        for (uint index = ThreadID; index < (uint)tileTxCount; index += threadCount) {
          uint apertureIndex = (uint)tileStart + index;
          uint sampleInputIndex =
              scattererIndex * (ApertureSampleCount * TransmissionCount) + transmissionIndex * ApertureSampleCount + apertureIndex;
          transmissionAperture[index] = pushData.transmissionResponses[sampleInputIndex];
        }
        for (uint index = ThreadID; index < (uint)tileRxCount; index += threadCount) {
          uint apertureIndex = (uint)tileRxStart + index;
          uint sampleInputIndex =
              scattererIndex * (ApertureSampleCount * ReceiveChannelCount) + receiveChannelIndex * ApertureSampleCount + apertureIndex;
          receiveChannelAperture[index] = pushData.getReceiveChannelResponses()[sampleInputIndex];
        }
        GroupMemoryBarrierWithGroupSync();

        for (int kt = 0; kt < tileTxCount; kt++) {
          int kr = s - (tileStart + kt);
          if (kr >= tileRxStart && kr <= tileRxEnd) {
            sample += transmissionAperture[kt] * receiveChannelAperture[kr - tileRxStart];
          }
        }
        GroupMemoryBarrierWithGroupSync();
      }
    }
  }

  uint dataLineIndex = transmissionIndex * ReceiveChannelCount + receiveChannelIndex;
  if (sampleInRange)
    pushData.response[dataLineIndex * ResponseSampleCount + sampleIndex] += sample;
}
