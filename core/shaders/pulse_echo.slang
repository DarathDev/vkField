module pulse_echo;

import pulse_echo_common;
import util;

layout(constant_id =  0) const uint  WorkgroupSizeX    = 64;
layout(constant_id =  1) const uint  SampleCount       = 0;
layout(constant_id =  2) const uint  TransmitCount     = 0;
layout(constant_id =  3) const uint  ReceiveBatchCount = 0;
layout(constant_id =  4) const uint  ScatterBatchCount = 0;
layout(constant_id =  5) const bool  Cumulative        = false;

struct PulseEchoSettings {
	uint receiveBatchOffset;
};

[[vk::push_constant]]
ConstantBuffer<PulseEchoSettings> settings;

float b2f(bool v) {
  return v ? 1.0f : 0.0f;
}

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

groupshared float output_samples[WorkgroupSizeX];

[shader("compute")]
[numthreads(WorkgroupSizeX, 1, 1)]
void main(uint3 GroupID: SV_GroupID, uint ThreadID: SV_GroupIndex)
{
	const uint thread_count = WorkgroupSizeX;

	uint base_sample   = WorkgroupSizeX * GroupID.x;
	uint receive_index = GroupID.y;

	output_samples[ThreadID] = 0;

	uint n_total       = ScatterBatchCount * TransmitCount;
	uint n_per_thread  = n_total / thread_count;
	uint n_leftover    = n_total % thread_count;
	uint n_this_thread = n_per_thread + uint(ThreadID < n_leftover);

	for (uint n = 0; n < n_this_thread; n++) {
		uint packed_index   = thread_count * n + ThreadID;
		uint scatter_index  = packed_index / TransmitCount;
		uint transmit_index = packed_index % TransmitCount;

		uint t_index = scatter_index * TransmitCount + transmit_index;
		uint r_index = ScatterBatchCount * TransmitCount + scatter_index * ReceiveBatchCount + receive_index;

		float4 r_rect_samples = packed_scatter_rects[r_index];
		float  r_scale        = packed_scatter_scales[r_index];
		float4 t_rect_samples = packed_scatter_rects[t_index];
		float  t_scale        = packed_scatter_scales[t_index];

		for (int sample_index = 0; sample_index < WorkgroupSizeX; sample_index++) {
			GroupMemoryBarrierWithGroupSync();
			int sample_n      = (sample_index + ThreadID) % WorkgroupSizeX;
			int full_sample_n = base_sample + sample_n;
			if (full_sample_n < SampleCount) {
				int minK = int(max(floor(t_rect_samples.x - 0.5f), full_sample_n - ceil(r_rect_samples.w + 0.5f)));
				int maxK = int(min(ceil(t_rect_samples.w + 0.5f),  full_sample_n - floor(r_rect_samples.x - 0.5f)));

				float sum = 0;
				for (int i = minK; i <= maxK; i++) {
					float vT = sample_transmit_aperture(i, t_rect_samples);
					float vR = sample_receive_aperture(full_sample_n, i, r_rect_samples);
					sum += vT * vR;
				}
				output_samples[sample_n] += t_scale * r_scale * sum;
			}
		}
	}

	GroupMemoryBarrierWithGroupSync();
	uint sample_index      = base_sample + ThreadID;
	uint receive_out_index = settings.receiveBatchOffset + receive_index;
	if (sample_index < SampleCount)
		response[receive_out_index * SampleCount + sample_index] += output_samples[ThreadID];
}
