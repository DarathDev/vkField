module temporalResponse;

import util;

[vk::constant_id(10)]
public const uint SampleWorkgroupSize = 64;
[vk::constant_id(11)]
public const uint MaxImpulseLength = 1;
[vk::constant_id(12)]
public const uint MaxExcitationLength = 1;

struct TemporalResponseSettings {
  float *response;
  float *temporalOutput;
  float *temporalResponses;
  uint lineIndex;
  uint impulseIndex;
  uint excitationIndex;
  uint receiveImpulseIndex;
  uint impulseLibraryCount;
  uint impulseCount;
  uint excitationCount;
  uint receiveImpulseCount;
  uint sampleOffset;
  float sampleInterval;
};

[[vk::push_constant]]
ConstantBuffer<TemporalResponseSettings> pushData;

groupshared float impulseResponse[MaxImpulseLength];
groupshared float excitationResponse[MaxExcitationLength];
groupshared float receiveImpulseResponse[MaxImpulseLength];

[shader("compute")]
[numthreads(SampleWorkgroupSize, 1, 1)]
void main(uint1 LocalInvocationID : SV_GroupThreadID, uint1 GroupID : SV_GroupID) {
  uint threadIndex = LocalInvocationID.x;
  uint outputIndex = pushData.sampleOffset + GroupID.x * SampleWorkgroupSize + threadIndex;

  for (uint responseIndex = threadIndex; responseIndex < MaxImpulseLength; responseIndex += SampleWorkgroupSize) {
    impulseResponse[responseIndex] = pushData.impulseIndex == 0 ? 0 :
      pushData.temporalResponses[(pushData.impulseIndex - 1) * MaxImpulseLength + responseIndex];
    receiveImpulseResponse[responseIndex] = pushData.receiveImpulseIndex == 0 ? 0 :
      pushData.temporalResponses[(pushData.receiveImpulseIndex - 1) * MaxImpulseLength + responseIndex];
  }
  for (uint responseIndex = threadIndex; responseIndex < MaxExcitationLength; responseIndex += SampleWorkgroupSize) {
    excitationResponse[responseIndex] = pushData.excitationIndex == 0 ? 0 :
      pushData.temporalResponses[pushData.impulseLibraryCount * MaxImpulseLength +
                                 (pushData.excitationIndex - 1) * MaxExcitationLength + responseIndex];
  }
  if (threadIndex == 0) {
    if (pushData.impulseIndex == 0) impulseResponse[0] = 1;
    if (pushData.excitationIndex == 0) excitationResponse[0] = 1;
    if (pushData.receiveImpulseIndex == 0) receiveImpulseResponse[0] = 1;
  }
  GroupMemoryBarrierWithGroupSync();

  if (outputIndex >= ResponseSampleCount) return;

  uint baseIndex = pushData.lineIndex * ResponseSampleCount;

  float sample = 0;
  uint impulseLength = pushData.impulseIndex == 0 ? 1 : pushData.impulseCount;
  uint excitationLength = pushData.excitationIndex == 0 ? 1 : pushData.excitationCount;
  uint receiveImpulseLength = pushData.receiveImpulseIndex == 0 ? 1 : pushData.receiveImpulseCount;
  float temporalScale = 1;
  if (pushData.impulseIndex != 0) temporalScale *= pushData.sampleInterval;
  if (pushData.excitationIndex != 0) temporalScale *= pushData.sampleInterval;
  if (pushData.receiveImpulseIndex != 0) temporalScale *= pushData.sampleInterval;

  for (uint impulseIndex = 0; impulseIndex < impulseLength; impulseIndex++) {
    float impulseValue = impulseResponse[impulseIndex];
    for (uint excitationIndex = 0; excitationIndex < excitationLength; excitationIndex++) {
      float excitationValue = excitationResponse[excitationIndex];
      for (uint receiveIndex = 0; receiveIndex < receiveImpulseLength; receiveIndex++) {
        float receiveValue = receiveImpulseResponse[receiveIndex];
        int inputIndex = int(outputIndex) - int(impulseIndex + excitationIndex + receiveIndex);
        if (inputIndex >= 0) {
          sample += pushData.response[baseIndex + inputIndex] * impulseValue *
                    excitationValue * receiveValue;
        }
      }
    }
  }
  pushData.temporalOutput[baseIndex + outputIndex] = sample * temporalScale;
}
