package vkfield

import "base:intrinsics"
import "core:math/linalg"
import "core:simd"
import "core:slice"
import utility "vkField:utility"

cpuSimulator :: struct {}

create_cpu_simulator :: proc() -> (simulator: cpuSimulator, ok := true) { return }
destroy_cpu_simulator :: proc(simulator: ^cpuSimulator) { return }

maxTransmitSirSize: f32
maxReceiveSirSize: f32

plan_cpu_simulation :: proc(
	simulator: ^cpuSimulator,
	settings: SimulationSettings,
	transmitElements: #soa[]RectangularElement,
	receiveElements: #soa[]RectangularElement,
) -> (
	ok := true,
) {
	maxTransmitSirSize = 0
	maxReceiveSirSize = 0
	for transmit in transmitElements {
		maxTransmitSirSize = max(maxTransmitSirSize, linalg.length(transmit.size))
	}
	for receive in receiveElements {
		maxReceiveSirSize = max(maxReceiveSirSize, linalg.length(receive.size))
	}
	maxTransmitSirSize *= settings.samplingFrequency / settings.speedOfSound
	maxReceiveSirSize *= settings.samplingFrequency / settings.speedOfSound
	return
}

simulate_cpu :: proc(
	simulator: ^cpuSimulator,
	settings: SimulationSettings,
	transmitElements: #soa[]RectangularElement,
	receiveElements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	data: []f32,
	ok := true,
) {
	utility.prof_scoped(#procedure)
	data = make([]f32, settings.sampleCount * settings.receiveElementCount)
	transmitApertureSampling = make([]f32, int(linalg.ceil(maxTransmitSirSize)) + 3)
	receiveApertureSampling = make([]f32, int(linalg.ceil(maxReceiveSirSize)) + 3)
	defer delete(transmitApertureSampling)
	defer delete(receiveApertureSampling)

	scatterCount: int = auto_cast settings.scatterCount
	transmitCount: int = auto_cast settings.transmitElementCount
	receiveCount: int = auto_cast settings.receiveElementCount

	// TODO: Add multi-core support
	SCATTER_BATCH_SIZE :: 16
	RECEIVE_BATCH_SIZE :: 16

	transmitImpulseResponses := make([]ImpulseResponse, transmitCount * SCATTER_BATCH_SIZE, context.temp_allocator)
	receiveImpulseResponses := make([]ImpulseResponse, RECEIVE_BATCH_SIZE * SCATTER_BATCH_SIZE, context.temp_allocator)

	scatterBaseIndex := 0
	for scatterBaseIndex < scatterCount {
		s := scatters[scatterBaseIndex:][:min(SCATTER_BATCH_SIZE, scatterCount - scatterBaseIndex)]
		scatterBaseIndex += SCATTER_BATCH_SIZE
		// This should be shared between all threads, TODO: add synchronization in the outer loop
		for scatter, scatterIndex in s {
			for transmitElement, transmitIndex in transmitElements {
				arrayIndex := scatterIndex * transmitCount + transmitIndex
				transmitImpulseResponses[arrayIndex] = get_spatial_impulse_response(settings, transmitElement, scatter)
			}
		}

		receiveBatchIndex := 0
		r: #soa[]RectangularElement
		for receiveBatchIndex < receiveCount {
			r = receiveElements[receiveBatchIndex:][:min(RECEIVE_BATCH_SIZE, receiveCount - receiveBatchIndex)]

			for scatter, scatterIndex in s {
				for receiveElement, receiveIndex in r {
					arrayIndex := scatterIndex * RECEIVE_BATCH_SIZE + receiveIndex
					receiveImpulseResponses[arrayIndex] = get_spatial_impulse_response(settings, receiveElement, scatter)
					receiveImpulseResponses[arrayIndex].rect -= settings.startTime * settings.samplingFrequency
				}
			}
			dataLine := data[receiveBatchIndex * auto_cast settings.sampleCount:][:settings.sampleCount * auto_cast len(r)]
			simulate_cpu_partial(settings, len(s), transmitImpulseResponses[:len(s) * transmitCount], receiveImpulseResponses[:len(s) * len(r)], dataLine)
			receiveBatchIndex += RECEIVE_BATCH_SIZE
		}
	}

	return
}

ImpulseResponse :: struct {
	rect:  [4]f32,
	scale: f32,
}

SIMD32_WIDTH :: 16
SIMD_F32 :: #simd[SIMD32_WIDTH]f32
SIMD_I32 :: #simd[SIMD32_WIDTH]i32
SIMD_U32 :: #simd[SIMD32_WIDTH]u32

simulate_cpu_partial :: proc(
	settings: SimulationSettings,
	scatterCount: int,
	transmitImpulseResponses: []ImpulseResponse,
	receiveImpulseResponses: []ImpulseResponse,
	data: []f32,
) -> (
	ok := true,
) {
	utility.prof_scoped(#procedure)
	transmitCount := len(transmitImpulseResponses) / scatterCount
	receiveCount := len(receiveImpulseResponses) / scatterCount

	assert(len(data) == auto_cast settings.sampleCount * receiveCount)

	for receiveIndex in 0 ..< receiveCount {
		dataLine := data[receiveIndex * auto_cast settings.sampleCount:][:settings.sampleCount]
		for scatterIndex in 0 ..< scatterCount {
			receiveImpulseResponse := receiveImpulseResponses[scatterIndex * receiveCount + receiveIndex]

			rMinSample := i32(linalg.floor(receiveImpulseResponse.rect.x - 0.5))
			rMaxSample := i32(linalg.ceil(receiveImpulseResponse.rect.w + 0.5))
			rSampleCount := rMaxSample - rMinSample + 1
			if rSampleCount <= 0 do continue
			assert(len(receiveApertureSampling) >= auto_cast rSampleCount)
			slice.zero(receiveApertureSampling)
			rSamples := receiveApertureSampling[:rSampleCount]
			sample_aperture_into(rSamples, rSampleCount, rMinSample, receiveImpulseResponse.rect, auto_cast settings.cumulative)

			for transmitIndex in 0 ..< transmitCount {
				transmitImpulseResponse := transmitImpulseResponses[scatterIndex * transmitCount + transmitIndex]

				tMinSample := i32(linalg.floor(transmitImpulseResponse.rect.x - 0.5))
				tMaxSample := i32(linalg.ceil(transmitImpulseResponse.rect.w + 0.5))
				tSampleCount := tMaxSample - tMinSample + 1
				if tSampleCount <= 0 || rSampleCount <= 0 do continue
				assert(len(transmitApertureSampling) >= auto_cast tSampleCount)
				slice.zero(transmitApertureSampling)
				tSamples := transmitApertureSampling[:tSampleCount]
				sample_aperture_into(tSamples, tSampleCount, tMinSample, transmitImpulseResponse.rect, auto_cast settings.cumulative)

				minSample := i32(linalg.floor(transmitImpulseResponse.rect.x + receiveImpulseResponse.rect.x - 0.5))
				maxSample := i32(linalg.ceil(transmitImpulseResponse.rect.w + receiveImpulseResponse.rect.w + 1.5))
				minSample = max(minSample, 0)
				maxSample = min(maxSample, auto_cast settings.sampleCount)
				if minSample >= maxSample do continue

				d := dataLine[minSample:maxSample]
				for chunkBase := 0; chunkBase < len(d); chunkBase += SIMD32_WIDTH {
					sampleOffset := minSample + i32(chunkBase)
					chunkWidth := min(SIMD32_WIDTH, len(d) - chunkBase)
					index := simd.iota(SIMD_I32)
					mask := simd.lanes_lt(index, auto_cast chunkWidth)

					tir := transmitImpulseResponse.rect
					rir := receiveImpulseResponse.rect

					minK := max(cast(i32)linalg.floor(tir.x - 0.5), sampleOffset - cast(i32)linalg.ceil(rir.w + 0.5))
					maxK := min(cast(i32)linalg.ceil(tir.w + 0.5), sampleOffset + auto_cast chunkWidth - cast(i32)linalg.floor(rir.x - 0.5))
					if minK > maxK do continue

					n := SIMD_I32(sampleOffset) + simd.iota(SIMD_I32)
					sum := SIMD_F32(0)
					for k in minK ..= maxK {
						kt := k - tMinSample
						tSamples: SIMD_F32
						if 0 <= kt && kt < tSampleCount {
							tSamples = SIMD_F32(transmitApertureSampling[kt])
						}
						#no_bounds_check {
							kr := n - k - rMinSample
							kr0 := sampleOffset - k - rMinSample
							krMask := simd.bit_and(simd.lanes_ge(kr, 0), simd.lanes_lt(kr, SIMD_I32(rSampleCount)))
							rSamples := simd.masked_load(cast(^SIMD_F32)raw_data(rSamples[kr0:]), SIMD_F32(0), krMask)
							sum += tSamples * rSamples
						}
					}
					dataPtr := cast(^SIMD_F32)raw_data(d[chunkBase:])
					d := simd.masked_load(dataPtr, cast(SIMD_F32)0, mask)
					d += sum * transmitImpulseResponse.scale * receiveImpulseResponse.scale
					simd.masked_store(dataPtr, d, mask)
				}
			}
		}
	}

	return
}

get_spatial_impulse_response :: proc(settings: SimulationSettings, element: RectangularElement, scatter: Scatter) -> (impulseResponse: ImpulseResponse) {
	utility.prof_scoped(#procedure)

	rotationAngle := linalg.quaternion_between_two_vector3(element.normal, [3]f32{0, 0, 1})
	rotation := linalg.matrix4_from_quaternion(rotationAngle)
	transform := rotation * linalg.matrix4_translate(element.position)
	scatterPosition := linalg.matrix_mul_vector(transform, [4]f32{**scatter.position, 1}).xyz
	dieProjection := linalg.abs(element.size * scatterPosition.xy)
	distance := linalg.length(scatterPosition)
	t0 := distance / settings.speedOfSound
	dt1 := linalg.min_single(dieProjection) / distance / settings.speedOfSound
	dt2 := linalg.max_single(dieProjection) / distance / settings.speedOfSound

	rectTimes := t0 + 0.5 * (dt1 * [4]f32{-1, +1, -1, +1} + dt2 * [4]f32{-1, -1, +1, +1})
	impulseResponse.rect = rectTimes * settings.samplingFrequency
	dt := 1 / settings.samplingFrequency

	powerDenominator := impulseResponse.rect.w - impulseResponse.rect.x <= 1 ? dt : dt2
	impulseResponse.scale =
		linalg.sqrt(scatter.amplitude) * element.apodization * element.size.x * element.size.y / (2 * linalg.PI * distance * powerDenominator)
	return
}

transmitApertureSampling: []f32
receiveApertureSampling: []f32

sample_aperture_into :: proc(samples: []f32, sampleCount, minSample: i32, aperture: [4]f32, cumulative: bool) {
	for chunkBase: i32 = 0; chunkBase < sampleCount; chunkBase += SIMD32_WIDTH {
		indices := chunkBase + simd.iota(SIMD_I32)
		mask := simd.lanes_lt(indices, SIMD_I32(sampleCount))

		chunkSamples := SIMD_F32(0)
		if !cumulative {
			chunkSamples = sample_aperture_discrete(indices + minSample, aperture)
		} else {
			chunkSamples = sample_aperture_cumulative(indices + minSample, aperture) - sample_aperture_cumulative(indices + minSample - 1, aperture)
		}

		simd.masked_store(cast(^SIMD_F32)raw_data(samples[int(chunkBase):]), chunkSamples, mask)
	}
}

sample_aperture_discrete :: proc(n: SIMD_I32, aperture: [4]f32) -> (result: SIMD_F32) {
	le :: simd.lanes_le
	gt :: simd.lanes_gt
	ge :: simd.lanes_ge
	and :: simd.bit_and
	select :: simd.select

	nf := cast(SIMD_F32)n
	value := SIMD_F32(0)

	if qDelta := aperture.w - aperture.x <= 1; qDelta {
		sDelta := 1 - simd.abs(nf - aperture.x)
		return simd.clamp(sDelta, SIMD_F32(0), SIMD_F32(1))
	}

	if qRect := aperture.y - aperture.x <= 1; qRect {
		qRectLeft := and(ge(nf, SIMD_F32(aperture.y - 0.5)), le(nf, SIMD_F32(aperture.y + 0.5)))
		sRectLeft := nf - (aperture.y - 0.5)
		value = select(SIMD_U32(and(SIMD_U32(qRect), qRectLeft)), sRectLeft, value)
		qRectCenter := and(gt(nf, SIMD_F32(aperture.y + 0.5)), le(nf, SIMD_F32(aperture.z - 0.5)))
		sRectCenter := SIMD_F32(1)
		value = select(SIMD_U32(and(SIMD_U32(qRect), qRectCenter)), sRectCenter, value)
		qRectRight := and(gt(nf, SIMD_F32(aperture.z - 0.5)), le(nf, SIMD_F32(aperture.z + 0.5)))
		sRectRight := 1 - (nf - (aperture.z - 0.5))
		value = select(SIMD_U32(and(SIMD_U32(qRect), qRectRight)), sRectRight, value)
		return simd.clamp(value, SIMD_F32(0), SIMD_F32(1))
	}

	if qTri := aperture.z - aperture.y <= 1; qTri {
		qTriLeft := and(ge(nf, SIMD_F32(aperture.x)), le(nf, SIMD_F32(aperture.y)))
		sTriLeft := (nf - aperture.x) / (aperture.y - aperture.x + linalg.F32_EPSILON)
		value = select(SIMD_U32(and(SIMD_U32(qTri), qTriLeft)), sTriLeft, value)
		qTriRight := and(gt(nf, SIMD_F32(aperture.z)), le(nf, SIMD_F32(aperture.w)))
		sTriRight := (1 - (nf - aperture.z) / (aperture.w - aperture.z + linalg.F32_EPSILON))
		value = select(SIMD_U32(and(SIMD_U32(qTri), qTriRight)), sTriRight, value)
		return simd.clamp(value, SIMD_F32(0), SIMD_F32(1))
	}

	if qTrap := true; qTrap {
		qTrapLeft := and(ge(nf, SIMD_F32(aperture.x)), le(nf, SIMD_F32(aperture.y)))
		sTrapLeft := (nf - aperture.x) / (aperture.y - aperture.x + linalg.F32_EPSILON)
		value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapLeft)), sTrapLeft, value)
		qTrapCenter := and(gt(nf, SIMD_F32(aperture.y)), le(nf, SIMD_F32(aperture.z)))
		sTrapCenter := SIMD_F32(1)
		value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapCenter)), sTrapCenter, value)
		qTrapRight := and(gt(nf, SIMD_F32(aperture.z)), le(nf, SIMD_F32(aperture.w)))
		sTrapRight := (1 - (nf - aperture.z) / (aperture.w - aperture.z + linalg.F32_EPSILON))
		value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapRight)), sTrapRight, value)
		return simd.clamp(value, SIMD_F32(0), SIMD_F32(1))
	}
	return
}

sample_aperture_cumulative :: proc(n: SIMD_I32, aperture: [4]f32) -> (result: SIMD_F32) {
	utility.prof_scoped(#procedure)

	ge :: simd.lanes_ge
	or :: simd.bit_or
	select :: simd.select
	clamp :: simd.clamp

	nf := cast(SIMD_F32)n
	value := SIMD_F32(0)

	qDelta := aperture.w - aperture.x <= 1
	qRect := !qDelta && (aperture.y - aperture.x <= 1)
	qTri := !qDelta && (aperture.z - aperture.y <= 1)
	qTrap := !(qDelta | qRect | qTri)

	if qDelta {
		return select(ge(nf, SIMD_F32(aperture.x)), SIMD_F32(1), SIMD_F32(0))
	}

	if qRect | qTrap {
		sRect := (aperture.z - aperture.y) * clamp((nf - aperture.y) / (aperture.z - aperture.y + linalg.F32_EPSILON), SIMD_F32(0), SIMD_F32(1))
		value += sRect
	}

	if qTri | qTrap {
		sTriLeftSat := clamp((nf - aperture.x) / (aperture.y - aperture.x + linalg.F32_EPSILON), SIMD_F32(0), SIMD_F32(1))
		sTriLeft := 0.5 * (aperture.y - aperture.x) * sTriLeftSat * sTriLeftSat
		sTriRightSat := clamp((aperture.w - nf) / (aperture.w - aperture.z + linalg.F32_EPSILON), SIMD_F32(0), SIMD_F32(1))
		sTriRight := 0.5 * (aperture.w - aperture.z) * (1 - sTriRightSat * sTriRightSat)
		value += sTriLeft + sTriRight
	}

	return value
}
