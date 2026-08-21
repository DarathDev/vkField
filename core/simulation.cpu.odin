package vkfield

import "core:math/linalg"
import "core:simd"
import utility "vkField:utility"

cpuSimulator :: struct {}

create_cpu_simulator :: proc() -> (simulator: cpuSimulator, ok := true) { return }
destroy_cpu_simulator :: proc(simulator: ^cpuSimulator) { return }

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
			for transmitIndex in 0 ..< transmitCount {
				transmitImpulseResponse := transmitImpulseResponses[scatterIndex * transmitCount + transmitIndex]

				d := dataLine
				sampleOffset: i32 = 0
				for len(d) >= SIMD32_WIDTH {
					process_chunk(
						d,
						sampleOffset,
						transmitImpulseResponse.rect,
						receiveImpulseResponse.rect,
						transmitImpulseResponse.scale * receiveImpulseResponse.scale,
						max(u32),
						auto_cast settings.cumulative,
					)
					utility.prof_begin("advance dataline")
					d = d[SIMD32_WIDTH:]
					utility.prof_end()
					sampleOffset += SIMD32_WIDTH
				}

				if len(d) > 0 {
					index := simd.iota(SIMD_I32)
					mask := simd.lanes_lt(index, auto_cast len(d))
					process_chunk(
						d,
						sampleOffset,
						transmitImpulseResponse.rect,
						receiveImpulseResponse.rect,
						transmitImpulseResponse.scale * receiveImpulseResponse.scale,
						mask,
						auto_cast settings.cumulative,
					)
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

process_chunk :: proc(
	data: []f32,
	sampleOffset: i32,
	transmitImpulseResponses: [4]f32,
	receiveImpulseResponses: [4]f32,
	scale: f32,
	mask: SIMD_U32,
	cumulative: bool,
) {
	utility.prof_scoped(#procedure)
	sampleIndex := simd.iota(SIMD_I32)
	sampleIndex = sampleIndex + cast(SIMD_I32)sampleOffset

	tir := transmitImpulseResponses
	rir := receiveImpulseResponses

	minK := simd.max(cast(SIMD_I32)linalg.floor(tir.x - 0.5), sampleIndex - cast(SIMD_I32)linalg.ceil(rir.w + 0.5))
	maxK := simd.min(cast(SIMD_I32)linalg.ceil(tir.w + 0.5), sampleIndex - cast(SIMD_I32)linalg.floor(rir.x - 0.5))

	minKAll := simd.reduce_min(minK)
	maxKAll := simd.reduce_max(maxK)

	if minKAll > maxKAll do return

	sum := SIMD_F32(0)
	utility.prof_begin("convolution")
	for k in minKAll ..= maxKAll {
		tSample, rSample: SIMD_F32
		if !cumulative {
			tSample = sample_aperture_discrete(k, tir)
			rSample = sample_aperture_discrete(sampleIndex - cast(SIMD_I32)k, rir)
		} else {
			tSample = sample_aperture_cumulative(k, tir) - sample_aperture_cumulative(k - 1, tir)
			rSample = sample_aperture_cumulative(sampleIndex - cast(SIMD_I32)k + 1, rir) - sample_aperture_cumulative(sampleIndex - cast(SIMD_I32)k, rir)
		}
		sumMask := simd.bit_and(simd.lanes_le(minK, SIMD_I32(k)), simd.lanes_ge(maxK, SIMD_I32(k)))
		sum += simd.select(sumMask, tSample * rSample, SIMD_F32(0))
	}
	utility.prof_end()
	utility.prof_begin("data save")
	dataPtr := cast(^SIMD_F32)raw_data(data)
	d := simd.masked_load(dataPtr, cast(SIMD_F32)0, mask)
	d += sum * scale
	simd.masked_store(dataPtr, d, mask)
	utility.prof_end()
}

sample_aperture_discrete :: proc(n: SIMD_I32, aperture: [4]f32) -> (result: SIMD_F32) {
	le :: simd.lanes_le
	gt :: simd.lanes_gt
	ge :: simd.lanes_ge
	and :: simd.bit_and
	select :: simd.select

	nf := cast(SIMD_F32)n
	value := SIMD_F32(0)

	qDelta := aperture.w - aperture.x <= 1
	sDelta := 1 - simd.abs(nf - aperture.x)
	value = select(SIMD_U32(qDelta), sDelta, value)

	qRect := !qDelta && (aperture.y - aperture.x <= 1)

	qRectLeft := and(ge(nf, SIMD_F32(aperture.y - 0.5)), le(nf, SIMD_F32(aperture.y + 0.5)))
	sRectLeft := nf - (aperture.y - 0.5)
	value = select(SIMD_U32(and(SIMD_U32(qRect), qRectLeft)), sRectLeft, value)
	qRectCenter := and(gt(nf, SIMD_F32(aperture.y + 0.5)), le(nf, SIMD_F32(aperture.z - 0.5)))
	sRectCenter := SIMD_F32(1)
	value = select(SIMD_U32(and(SIMD_U32(qRect), qRectCenter)), sRectCenter, value)
	qRectRight := and(gt(nf, SIMD_F32(aperture.z - 0.5)), le(nf, SIMD_F32(aperture.z + 0.5)))
	sRectRight := 1 - (nf - (aperture.z - 0.5))
	value = select(SIMD_U32(and(SIMD_U32(qRect), qRectRight)), sRectRight, value)

	qTri := !qDelta && (aperture.z - aperture.y <= 1)
	qTriLeft := and(ge(nf, SIMD_F32(aperture.x)), le(nf, SIMD_F32(aperture.y)))
	sTriLeft := (nf - aperture.x) / (aperture.y - aperture.x + linalg.F32_EPSILON)
	value = select(SIMD_U32(and(SIMD_U32(qTri), qTriLeft)), sTriLeft, value)
	qTriRight := and(gt(nf, SIMD_F32(aperture.z)), le(nf, SIMD_F32(aperture.w)))
	sTriRight := (1 - (nf - aperture.z) / (aperture.w - aperture.z + linalg.F32_EPSILON))
	value = select(SIMD_U32(and(SIMD_U32(qTri), qTriRight)), sTriRight, value)

	qTrap := !(qDelta | qRect | qTri)
	qTrapLeft := qTriLeft
	sTrapLeft := sTriLeft
	value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapLeft)), sTrapLeft, value)
	qTrapCenter := and(gt(nf, SIMD_F32(aperture.y)), le(nf, SIMD_F32(aperture.z)))
	sTrapCenter := sRectCenter
	value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapCenter)), sTrapCenter, value)
	qTrapRight := qTriRight
	sTrapRight := sTriRight
	value = select(SIMD_U32(and(SIMD_U32(qTrap), qTrapRight)), sTrapRight, value)

	return simd.clamp(value, SIMD_F32(0), SIMD_F32(1))
}

sample_aperture_cumulative :: proc(n: SIMD_I32, aperture: [4]f32) -> (result: SIMD_F32) {
	ge :: simd.lanes_ge
	or :: simd.bit_or
	select :: simd.select
	clamp :: simd.clamp

	nf := cast(SIMD_F32)n
	value := SIMD_F32(0)

	qDelta := aperture.w - aperture.x <= 1
	sDelta := select(ge(nf, SIMD_F32(aperture.x)), SIMD_F32(1), SIMD_F32(0))
	value = select(SIMD_U32(qDelta), sDelta, value)

	qRect := !qDelta && (aperture.y - aperture.x <= 1)
	qTri := !qDelta && (aperture.z - aperture.y <= 1)
	qTrap := !(qDelta | qRect | qTri)

	sRect := (aperture.z - aperture.y) * clamp((nf - aperture.y) / (aperture.z - aperture.y + linalg.F32_EPSILON), SIMD_F32(0), SIMD_F32(1))
	value = select(SIMD_U32(qRect | qTrap), value + sRect, value)

	sTriLeftSat := clamp((nf - aperture.x) / (aperture.y - aperture.x + linalg.F32_EPSILON), SIMD_F32(0), SIMD_F32(1))
	sTriLeft := 0.5 * (aperture.y - aperture.x) * sTriLeftSat * sTriLeftSat
	sTriRightSat := clamp((aperture.w - nf) / (aperture.w - aperture.z + linalg.F32_EPSILON), SIMD_F32(0), SIMD_F32(1))
	sTriRight := 0.5 * (aperture.w - aperture.z) * (1 - sTriRightSat * sTriRightSat)
	value = select(SIMD_U32(qTri | qTrap), value + sTriLeft + sTriRight, value)

	return value
}
