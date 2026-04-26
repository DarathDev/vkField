module pulse_echo;

import pulse_echo_common;
import util;

[[vk::push_constant]]
public ConstantBuffer<PulseEchoSettings> settings;

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

float sample_transmit_aperture(in int i, in float4 nRectT) {
  return sample_rect_aperture_discrete(i, nRectT);
}

float sample_receive_aperture(in int n, in int i, in float4 nRectR) {
  return sample_rect_aperture_discrete(n - i, nRectR);
}
#endif

// TODO(rnp): spec constant
#define SAMPLE_BATCH_SIZE 64

groupshared float output_samples[SAMPLE_BATCH_SIZE];

[shader("compute")]
[numthreads(SAMPLE_BATCH_SIZE, 1, 1)]
void main(uint3 GroupID: SV_GroupID, uint ThreadID: SV_GroupIndex)
{
	const uint thread_count = SAMPLE_BATCH_SIZE;

	uint base_sample   = SAMPLE_BATCH_SIZE * GroupID.x;
	uint receive_index = GroupID.y;

	output_samples[ThreadID] = 0;

	uint n_total       = settings.scatterBatchCount * settings.transmitCount;
	uint n_per_thread  = n_total / thread_count;
	uint n_leftover    = n_total % thread_count;
	uint n_this_thread = n_per_thread + uint(ThreadID < n_leftover);

	for (uint n = 0; n < n_this_thread; n++) {
		uint packed_index   = thread_count * n + ThreadID;
		uint scatter_index  = packed_index / settings.transmitCount;
		uint transmit_index = packed_index % settings.transmitCount;

		uint t_index = scatter_index * settings.transmitCount + transmit_index;
		uint r_index = settings.scatterBatchCount * settings.transmitCount + scatter_index * settings.receiveCount + receive_index;

		float4 r_rect_samples = packed_scatter_rects[r_index];
		float  r_scale        = packed_scatter_scales[r_index];
		float4 t_rect_samples = packed_scatter_rects[t_index];
		float  t_scale        = packed_scatter_scales[t_index];

		for (int sample_index = 0; sample_index < SAMPLE_BATCH_SIZE; sample_index++) {
			GroupMemoryBarrierWithGroupSync();
			int sample_n      = (sample_index + ThreadID) % SAMPLE_BATCH_SIZE;
			int full_sample_n = base_sample + sample_n;
			if (full_sample_n < settings.sampleCount) {
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
	uint sample_index = base_sample + ThreadID;
	if (sample_index < settings.sampleCount)
		response[receive_index * settings.sampleCount + sample_index] += output_samples[ThreadID];
}
