module pulseEcho;

import util;

layout(constant_id = 0) const uint WorkgroupSizeX = 64;
layout(constant_id = 1) const uint SampleCount = 0;
layout(constant_id = 2) const uint TransmitCount = 0;
layout(constant_id = 3) const uint ReceiveBatchCount = 0;
layout(constant_id = 4) const uint ScatterBatchCount = 0;
layout(constant_id = 5) const bool Cumulative = false;

struct PulseEchoSettings {
  float4 *spatialImpulseResponses;
  float *response;
  uint receiveBatchOffset;
};

[[vk::push_constant]]
ConstantBuffer<PulseEchoSettings> settings;

float b2f(bool v) { return v ? 1.0f : 0.0f; }

float sample_rect_aperture_cumulative(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.w - rectSamples.x <= 1;
  bool qRect = !qDelta && (rectSamples.y - rectSamples.x <= 1);
  bool qTri = !qDelta && (rectSamples.z - rectSamples.y <= 1);
  bool qTrap = !(qDelta | qRect | qTri);

  float sDelta = n >= rectSamples.x ? 1 : 0;

  float sRect = (rectSamples.z - rectSamples.y) * saturate((n - rectSamples.y) / (rectSamples.z - rectSamples.y));

  float sTriLeftSat = saturate((n - rectSamples.x) / (rectSamples.y - rectSamples.x));
  float sTriLeft = 0.5f * (rectSamples.y - rectSamples.x) * sTriLeftSat * sTriLeftSat;
  float sTriRightSat = saturate((rectSamples.w - n) / (rectSamples.w - rectSamples.z));
  float sTriRight = 0.5f * (rectSamples.w - rectSamples.z) * (1 - sTriRightSat * sTriRightSat);

  float value =
      b2f(qDelta) * sDelta + b2f(qRect) * sRect + b2f(qTri) * (sTriLeft + sTriRight) + b2f(qTrap) * (sTriLeft + sRect + sTriRight);
  return value;
}

float sample_rect_aperture_discrete(in float n, in float4 rectSamples) {
  bool qDelta = rectSamples.w - rectSamples.x <= 1;
  bool qRect = !qDelta && (rectSamples.y - rectSamples.x <= 1);
  bool qTri = !qDelta && (rectSamples.z - rectSamples.y <= 1);
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

float sample_transmit_aperture(in int i, in float4 nRectT) {
  if (Cumulative) {
    return sample_rect_aperture_cumulative(i, nRectT) - sample_rect_aperture_cumulative(i - 1, nRectT);
  } else {
    return sample_rect_aperture_discrete(i, nRectT);
  }
}

float sample_receive_aperture(in int n, in int i, in float4 nRectR) {
  if (Cumulative) {
    return sample_rect_aperture_cumulative(n - i + 1, nRectR) - sample_rect_aperture_cumulative(n - i, nRectR);
  } else {
    return sample_rect_aperture_discrete(n - i, nRectR);
  }
}

groupshared float outputSamples[WorkgroupSizeX];

[shader("compute")]
[numthreads(WorkgroupSizeX, 1, 1)]
void main(uint3 GroupID: SV_GroupID, uint ThreadID: SV_GroupIndex) {
  const uint threadCount = WorkgroupSizeX;

  uint baseSample = WorkgroupSizeX * GroupID.x;
  uint receiveIndex = GroupID.y;

  outputSamples[ThreadID] = 0;

  uint nTotal = ScatterBatchCount * TransmitCount;
  uint nPerThread = nTotal / threadCount;
  uint nLeftover = nTotal % threadCount;
  uint nThisThread = nPerThread + uint(ThreadID < nLeftover);

  for (uint n = 0; n < nThisThread; n++) {
    uint packedIndex = threadCount * n + ThreadID;
    uint scatterIndex = packedIndex / TransmitCount;
    uint transmitIndex = packedIndex % TransmitCount;

    uint tIndex = scatterIndex * TransmitCount + transmitIndex;
    uint rIndex = ScatterBatchCount * TransmitCount + scatterIndex * ReceiveBatchCount + receiveIndex;

    float4 *sirRects = settings.spatialImpulseResponses;
    float *sirScales = Ptr<float>(sirRects + (ScatterBatchCount * (TransmitCount + ReceiveBatchCount)));

    float4 rRectSamples = sirRects[rIndex];
    float rScale = sirScales[rIndex];
    float4 tRectSamples = sirRects[tIndex];
    float tScale = sirScales[tIndex];

    for (int sampleIndex = 0; sampleIndex < WorkgroupSizeX; sampleIndex++) {
      GroupMemoryBarrierWithGroupSync();
      int sampleN = (sampleIndex + ThreadID) % WorkgroupSizeX;
      int fullSampleN = baseSample + sampleN;
      if (fullSampleN < SampleCount) {
        int minK = int(max(floor(tRectSamples.x - 0.5f), fullSampleN - ceil(rRectSamples.w + 0.5f)));
        int maxK = int(min(ceil(tRectSamples.w + 0.5f), fullSampleN - floor(rRectSamples.x - 0.5f)));

        float sum = 0;
        for (int i = minK; i <= maxK; i++) {
          float vT = sample_transmit_aperture(i, tRectSamples);
          float vR = sample_receive_aperture(fullSampleN, i, rRectSamples);
          sum += vT * vR;
        }
        outputSamples[sampleN] += tScale * rScale * sum;
      }
    }
  }

  GroupMemoryBarrierWithGroupSync();
  uint sampleIndex = baseSample + ThreadID;
  uint receiveOutIndex = settings.receiveBatchOffset + receiveIndex;
  if (sampleIndex < SampleCount)
    settings.response[receiveOutIndex * SampleCount + sampleIndex] += outputSamples[ThreadID];
}
