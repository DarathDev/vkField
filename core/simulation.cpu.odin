package vkfield

import "base:intrinsics"
import "core:math/linalg"
import "core:simd"
import "core:slice"
import utility "vkField:utility"

cpuSimulator :: struct {}

create_cpu_simulator :: proc() -> (simulator: cpuSimulator, ok := true) { return }
destroy_cpu_simulator :: proc(simulator: ^cpuSimulator) { return }

maxTransmitSirSize: i32
maxReceiveSirSize: i32

plan_cpu_simulation :: proc(
	simulator: ^cpuSimulator,
	settings: SimulationSettings,
	transmitElements: #soa[]RectangularElement,
	receiveElements: #soa[]RectangularElement,
) -> (
	ok := true,
) {
	maxTransmitSir: f32 = 0
	maxReceiveSir: f32 = 0
	for transmit in transmitElements {
		maxTransmitSir = max(maxTransmitSir, linalg.length(transmit.size))
	}
	for receive in receiveElements {
		maxReceiveSir = max(maxReceiveSir, linalg.length(receive.size))
	}
	maxTransmitSir *= settings.samplingFrequency / settings.speedOfSound
	maxReceiveSir *= settings.samplingFrequency / settings.speedOfSound
	maxTransmitSirSize = i32(linalg.ceil(maxTransmitSir))
	maxReceiveSirSize = i32(linalg.ceil(maxReceiveSir))
	maxTransmitSirSize += 3
	maxReceiveSirSize += 3
	maxTransmitSirSize = ((i32(maxTransmitSirSize) + SIMD32_WIDTH - 1) / SIMD32_WIDTH) * SIMD32_WIDTH
	maxReceiveSirSize = ((i32(maxReceiveSirSize) + SIMD32_WIDTH - 1) / SIMD32_WIDTH) * SIMD32_WIDTH
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

	// TODO: Add multi-core support	
	utility.prof_begin("Allocate")
	data = make([]f32, settings.sampleCount * settings.receiveElementCount)
	transmitImpulseResponses := make([]ImpulseResponse, auto_cast settings.transmitElementCount, context.temp_allocator)
	receiveImpulseResponses := make([]ImpulseResponse, auto_cast settings.receiveElementCount, context.temp_allocator)
	utility.prof_end()
	transmitApertureSampling: []f32
	receiveApertureSampling: []f32
	defer if len(transmitApertureSampling) > 0 do delete(transmitApertureSampling)
	defer if len(receiveApertureSampling) > 0 do delete(receiveApertureSampling)

	cumulative: bool = auto_cast settings.cumulative

	for scatter in scatters {
		utility.prof_scoped("Scatter")
		allTransmitMinSample := max(i32)
		allTransmitMaxSample := min(i32)

		for transmitElement, transmitIndex in transmitElements {
			utility.prof_scoped("Transmit Element SIR")
			transmitImpulseResponse := get_spatial_impulse_response(settings, transmitElement, scatter)
			allTransmitMinSample = min(allTransmitMinSample, i32(linalg.floor(transmitImpulseResponse.rect.x - 0.5)))
			allTransmitMaxSample = max(allTransmitMaxSample, i32(linalg.ceil(transmitImpulseResponse.rect.w + 0.5)))
			transmitImpulseResponses[transmitIndex] = transmitImpulseResponse
		}

		allTransmitSampleCount := allTransmitMaxSample - allTransmitMinSample + 1
		if allTransmitSampleCount <= 0 do continue

		if auto_cast len(transmitApertureSampling) < allTransmitSampleCount {
			utility.prof_begin("Allocate")
			if len(transmitApertureSampling) > 0 do delete(transmitApertureSampling)
			transmitApertureSampling = make([]f32, allTransmitSampleCount)
			utility.prof_end()
		} else {
			slice.zero(transmitApertureSampling)
		}

		for _, transmitIndex in transmitElements {
			utility.prof_scoped("Transmit Element Sampling")
			transmitImpulseResponse := transmitImpulseResponses[transmitIndex]
			transmitMinSample := i32(linalg.floor(transmitImpulseResponse.rect.x - 0.5))
			transmitMaxSample := i32(linalg.ceil(transmitImpulseResponse.rect.w + 0.5))

			if transmitImpulseResponse.scale == 0 do return

			sample_aperture_add(
				transmitApertureSampling[(transmitMinSample - allTransmitMinSample):(transmitMaxSample + 1 - allTransmitMinSample)],
				transmitMinSample,
				transmitImpulseResponse,
				auto_cast cumulative,
			)
		}

		for &value in transmitApertureSampling[:allTransmitSampleCount] {
			value *= scatter.amplitude
		}

		maxReceiveSampleCount: i32

		for receiveElement, receiveIndex in receiveElements {
			utility.prof_scoped("Reecive Element SIR")
			receiveImpulseResponse := get_spatial_impulse_response(settings, receiveElement, scatter)
			// One of the SIRs needs to be offset by the start time
			receiveImpulseResponse.rect -= settings.startTime * settings.samplingFrequency
			// Necessary for proper delaying in the cumulative case
			if cumulative do receiveImpulseResponse.rect -= 1
			receiveMinSample := i32(linalg.floor(receiveImpulseResponse.rect.x - 0.5))
			receiveMaxSample := i32(linalg.ceil(receiveImpulseResponse.rect.w + 0.5))
			maxReceiveSampleCount = max(maxReceiveSampleCount, receiveMaxSample - receiveMinSample + 1)
			receiveImpulseResponses[receiveIndex] = receiveImpulseResponse
		}

		if auto_cast len(receiveApertureSampling) < maxReceiveSampleCount {
			utility.prof_begin("Allocate")
			if len(receiveApertureSampling) > 0 do delete(receiveApertureSampling)
			receiveApertureSampling = make([]f32, maxReceiveSampleCount)
			utility.prof_end()
		} else {
			slice.zero(receiveApertureSampling)
		}

		for _, receiveIndex in receiveElements {
			utility.prof_scoped("Receive Element Sampling")
			receiveImpulseResponse := receiveImpulseResponses[receiveIndex]
			if receiveImpulseResponse.scale == 0 do return

			receiveMinSample := i32(linalg.floor(receiveImpulseResponse.rect.x - 0.5))
			receiveMaxSample := i32(linalg.ceil(receiveImpulseResponse.rect.w + 0.5))
			receiveSampleCount := receiveMaxSample - receiveMinSample + 1

			minSample := allTransmitMinSample + receiveMinSample
			maxSample := allTransmitMaxSample + receiveMaxSample + 1
			minSample = max(minSample, 0)
			maxSample = min(maxSample, auto_cast settings.sampleCount)
			if minSample >= maxSample do continue

			#no_bounds_check {
				sample_aperture_into(receiveApertureSampling[:receiveSampleCount], receiveMinSample, receiveImpulseResponse, cumulative)
			}

			utility.prof_scoped("Convolution")
			receiveDataLine := data[receiveIndex * auto_cast settings.sampleCount:][:settings.sampleCount]
			for baseSample := minSample; baseSample < maxSample; baseSample += SIMD32_WIDTH {
				samples := baseSample + simd.iota(SIMD_I32)
				sampleMask := simd.lanes_le(samples, SIMD_I32(maxSample))

				minK := max(allTransmitMinSample, baseSample - cast(i32)linalg.ceil(receiveImpulseResponse.rect.w + 0.5))
				maxK := min(allTransmitMaxSample, min(baseSample + SIMD32_WIDTH, maxSample) - cast(i32)linalg.floor(receiveImpulseResponse.rect.x - 0.5))
				if minK > maxK do continue

				sum := SIMD_F32(0)
				for k in minK ..= maxK {
					kt := k - allTransmitMinSample
					#no_bounds_check tSamples := SIMD_F32(transmitApertureSampling[kt])
					kr := samples - k - receiveMinSample
					kr0 := baseSample - k - receiveMinSample
					krMask := simd.bit_and(simd.lanes_ge(kr, 0), simd.lanes_lt(kr, SIMD_I32(receiveSampleCount)))
					#no_bounds_check rSamples := simd.masked_load(cast(^SIMD_F32)raw_data(receiveApertureSampling[kr0:]), SIMD_F32(0), krMask)
					sum += tSamples * rSamples
				}
				#no_bounds_check dataPtr := cast(^SIMD_F32)raw_data(receiveDataLine[baseSample:])
				d := simd.masked_load(dataPtr, cast(SIMD_F32)0, sampleMask)
				d += sum
				simd.masked_store(dataPtr, d, sampleMask)
			}
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
	impulseResponse.scale = element.apodization * element.size.x * element.size.y / (2 * linalg.PI * distance * powerDenominator)
	return
}

sample_aperture_into :: proc(samples: []f32, minSample: i32, impulseResponse: ImpulseResponse, cumulative: bool) {
	sampleCount := len(samples)
	for chunkBase: i32 = 0; chunkBase < auto_cast sampleCount; chunkBase += SIMD32_WIDTH {
		indices := chunkBase + simd.iota(SIMD_I32)
		mask := simd.lanes_lt(indices, SIMD_I32(sampleCount))

		chunkSamples := sample_aperture(indices + minSample, impulseResponse.rect, cumulative)
		chunkSamples *= impulseResponse.scale
		#no_bounds_check {
			simd.masked_store(cast(^SIMD_F32)raw_data(samples[int(chunkBase):]), chunkSamples, mask)
		}
	}
}

sample_aperture_add :: proc(samples: []f32, minSample: i32, impulseResponse: ImpulseResponse, cumulative: bool) {
	sampleCount := len(samples)
	for chunkBase: i32 = 0; chunkBase < auto_cast sampleCount; chunkBase += SIMD32_WIDTH {
		indices := chunkBase + simd.iota(SIMD_I32)
		mask := simd.lanes_lt(indices, SIMD_I32(sampleCount))

		chunkSamples := sample_aperture(indices + minSample, impulseResponse.rect, cumulative)
		chunkSamples *= impulseResponse.scale

		chunkSamples += simd.masked_load(cast(^SIMD_F32)raw_data(samples[int(chunkBase):]), SIMD_F32(0), mask)
		simd.masked_store(cast(^SIMD_F32)raw_data(samples[int(chunkBase):]), chunkSamples, mask)
	}
}

sample_aperture :: #force_inline proc(n: SIMD_I32, aperture: [4]f32, cumulative: bool) -> (result: SIMD_F32) {
	utility.prof_scoped(#procedure)
	return (!cumulative) ? sample_aperture_discrete(n, aperture) : sample_aperture_cumulative(n, aperture) - sample_aperture_cumulative(n - 1, aperture)
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
