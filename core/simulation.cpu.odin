package vkfield

import "base:intrinsics"
import "core:log"
import "core:math/linalg"
import "core:simd"
import "core:slice"
import "import:pffft"
import utility "vkField:utility"

cpuSimulator :: struct {}

create_cpu_simulator :: proc() -> (simulator: cpuSimulator, ok := true) { return }
destroy_cpu_simulator :: proc(simulator: ^cpuSimulator) { return }

maxSpatialImpulseResponseSize: i32

plan_cpu_simulation :: proc(simulator: ^cpuSimulator, settings: ^SimulationSettings) -> (ok := true) {
	// Round up to the nearest multiple of 32
	settings.sampleCount = (settings.sampleCount + (31)) & ~i32(31)
	return
}

simulate_cpu :: proc(
	simulator: ^cpuSimulator,
	settings: SimulationSettings,
	transmissions: []Transmission,
	receiveChannels: []ReceiveChannel,
	elements: #soa[]RectangularElement,
	scatters: []Scatter,
) -> (
	data: []f32,
	ok := true,
) {
	utility.prof_scoped(#procedure)

	// TODO: Add multi-core support

	cumulative: bool = auto_cast settings.cumulative
	samplingFrequency := settings.samplingFrequency
	startTime := settings.startTime
	speedOfSound := settings.speedOfSound

	sampleCount := settings.sampleCount
	transmissionCount: i32 = auto_cast len(transmissions)
	receiveChannelCount: i32 = auto_cast len(receiveChannels)

	utility.prof_begin("Allocate")
	data = make_aligned([]f32, sampleCount * receiveChannelCount * transmissionCount, 16)
	elementImpulses := make([]ImpulseResponse, auto_cast len(elements), context.allocator)
	transmissionMinSamples := make([]i32, transmissionCount, context.allocator)
	transmissionSampleCounts := make([]i32, transmissionCount, context.allocator)
	receiveChannelMinSamples := make([]i32, receiveChannelCount, context.allocator)
	receiveChannelSampleCounts := make([]i32, receiveChannelCount, context.allocator)
	// TODO: I might need to check the alignment of all subslices, they need to be 16-byte aligned
	transmissionImpulses := make_aligned([]f32, transmissionCount * sampleCount, 16, context.allocator)
	receiveChannelImpulses := make_aligned([]f32, receiveChannelCount * sampleCount, 16, context.allocator)
	defer {
		delete(elementImpulses)
		delete(transmissionImpulses)
		delete(receiveChannelImpulses)
		delete(transmissionMinSamples)
		delete(receiveChannelMinSamples)
		delete(transmissionSampleCounts)
		delete(receiveChannelSampleCounts)
	}
	utility.prof_end()

	// TODO: Choose where to put the scatter scaling

	for scatter, scatterIndex in scatters {
		utility.prof_scoped("Scatter")

		utility.prof_begin("Element SIR Calculation")
		for element, elementIndex in elements {
			elementImpulses[elementIndex] = get_spatial_impulse_response(speedOfSound, samplingFrequency, element, scatter)
		}
		utility.prof_end()

		utility.prof_begin("Transmission Impulse")
		for transmission, transmissionIndex in transmissions {

			utility.prof_begin("Transmission Precalculations")
			transmissionMinSample := max(i32)
			transmissionMaxSample := min(i32)
			for element in transmission.elements {
				elementImpulse := elementImpulses[element.index]
				elementImpulse.rect += element.delay / samplingFrequency
				elementImpulse.scale *= element.apodization
				if elementImpulse.scale == 0 do continue

				transmissionMinSample = min(transmissionMinSample, i32(linalg.floor(elementImpulse.rect.x - 0.5)))
				transmissionMaxSample = max(transmissionMaxSample, i32(linalg.ceil(elementImpulse.rect.w + 0.5)))
			}

			transmissionMinSamples[transmissionIndex] = transmissionMinSample
			transmissionSampleCounts[transmissionIndex] = transmissionMaxSample - transmissionMinSample + 1
			transmissionImpulse := transmissionImpulses[transmissionIndex * auto_cast sampleCount:][:sampleCount]
			slice.zero(transmissionImpulse)
			utility.prof_end()

			utility.prof_begin("Transmission Sampling")
			for element in transmission.elements {
				elementImpulse := elementImpulses[element.index]
				elementImpulse.rect += element.delay / samplingFrequency
				elementImpulse.scale *= element.apodization

				if elementImpulse.scale == 0 do return

				elementMinSample := i32(linalg.floor(elementImpulse.rect.x - 0.5))
				elementMaxSample := i32(linalg.ceil(elementImpulse.rect.w + 0.5))

				sample_aperture_add(
					transmissionImpulse[(elementMinSample - transmissionMinSample):(elementMaxSample + 1 - transmissionMinSample)],
					elementMinSample,
					elementImpulse,
					auto_cast cumulative,
				)
			}

			utility.prof_end()
		}
		utility.prof_end()

		utility.prof_begin("Receive Channel Impulse")
		for receiveChannel, receiveChannelIndex in receiveChannels {

			utility.prof_begin("Receive Channel Precalculations")
			receiveChannelMinSample := max(i32)
			receiveChannelMaxSample := min(i32)
			for element in receiveChannel.elements {
				elementImpulse := elementImpulses[element.index]
				elementImpulse.rect += element.delay / samplingFrequency
				elementImpulse.scale *= element.apodization
				// One of the impulse responses needs to be offset by the start time
				elementImpulse.rect -= startTime * samplingFrequency
				// Necessary for proper delaying in the cumulative case
				if cumulative do elementImpulse.rect -= 1
				if elementImpulse.scale == 0 do continue

				receiveChannelMinSample = min(receiveChannelMinSample, i32(linalg.floor(elementImpulse.rect.x - 0.5)))
				receiveChannelMaxSample = max(receiveChannelMaxSample, i32(linalg.ceil(elementImpulse.rect.w + 0.5)))
			}

			receiveChannelMinSamples[receiveChannelIndex] = receiveChannelMinSample
			receiveChannelSampleCounts[receiveChannelIndex] = receiveChannelMaxSample - receiveChannelMinSample + 1
			receiveChannelImpulse := receiveChannelImpulses[receiveChannelIndex * auto_cast sampleCount:][:sampleCount]
			slice.zero(receiveChannelImpulse)
			utility.prof_end()

			utility.prof_begin("Receive Channel Sampling")
			for element in receiveChannel.elements {
				elementImpulse := elementImpulses[element.index]
				elementImpulse.rect += element.delay / samplingFrequency
				elementImpulse.scale *= element.apodization
				// One of the impulse responses needs to be offset by the start time
				elementImpulse.rect -= startTime * samplingFrequency
				// Necessary for proper delaying in the cumulative case
				if cumulative do elementImpulse.rect -= 1

				if elementImpulse.scale == 0 do return

				elementMinSample := i32(linalg.floor(elementImpulse.rect.x - 0.5))
				elementMaxSample := i32(linalg.ceil(elementImpulse.rect.w + 0.5))

				sample_aperture_add(
					receiveChannelImpulse[(elementMinSample - receiveChannelMinSample):(elementMaxSample + 1 - receiveChannelMinSample)],
					elementMinSample,
					elementImpulse,
					auto_cast cumulative,
				)
			}

			utility.prof_end()
		}
		utility.prof_end()

		maxTransmissionSampleCount := slice.max(transmissionSampleCounts)
		maxReceiveChannelSampleCount := slice.max(receiveChannelSampleCounts)
		fftCount := pffft.adjust_n(auto_cast max(maxTransmissionSampleCount, maxReceiveChannelSampleCount))

		if fftCount < 128 {
			convolve_time_domain(
				sampleCount,
				transmissionCount,
				receiveChannelCount,
				scatter,
				transmissionMinSamples,
				receiveChannelMinSamples,
				transmissionSampleCounts,
				receiveChannelSampleCounts,
				transmissionImpulses,
				receiveChannelImpulses,
				data,
			)
		} else {
			convolve_frequency_domain(
				sampleCount,
				transmissionCount,
				receiveChannelCount,
				scatter,
				transmissionMinSamples,
				receiveChannelMinSamples,
				transmissionSampleCounts,
				receiveChannelSampleCounts,
				transmissionImpulses,
				receiveChannelImpulses,
				data,
			)
		}

	}
	return
}

convolve_time_domain :: proc(
	sampleCount, transmissionCount, receiveChannelCount: i32,
	scatter: Scatter,
	transmissionMinSamples, receiveChannelMinSamples, transmissionSampleCounts, receiveChannelSampleCounts: []i32,
	transmissionImpulses, receiveChannelImpulses, data: []f32,
) {
	utility.prof_scoped(#procedure)
	for transmissionIndex in 0 ..< transmissionCount {
		transmissionMinSample := transmissionMinSamples[transmissionIndex]
		transmissionSampleCount := transmissionSampleCounts[transmissionIndex]
		transmissionMaxSample := transmissionMinSample + transmissionSampleCount - 1
		transmissionImpulse := transmissionImpulses[transmissionIndex * auto_cast sampleCount:][:sampleCount]
		for receiveChannelIndex in 0 ..< receiveChannelCount {
			receiveChannelMinSample := receiveChannelMinSamples[receiveChannelIndex]
			receiveChannelSampleCount := receiveChannelSampleCounts[receiveChannelIndex]
			receiveChannelMaxSample := receiveChannelMinSample + receiveChannelSampleCount - 1
			receiveChannelImpulse := receiveChannelImpulses[receiveChannelIndex * auto_cast sampleCount:][:sampleCount]

			minSample := transmissionMinSample + receiveChannelMinSample
			maxSample := transmissionMaxSample + receiveChannelMaxSample + 1
			minSample = max(minSample, 0)
			maxSample = min(maxSample, auto_cast sampleCount)
			if minSample >= maxSample do continue

			#no_bounds_check receiveDataLine := data[(receiveChannelIndex + (transmissionIndex * receiveChannelCount)) * auto_cast sampleCount:][:sampleCount]

			for baseSample := minSample; baseSample < maxSample; baseSample += SIMD32_WIDTH {
				samples := baseSample + simd.iota(SIMD_I32)
				sampleMask := simd.lanes_le(samples, SIMD_I32(maxSample))

				minK := max(transmissionMinSample, baseSample - receiveChannelMaxSample)
				maxK := min(transmissionMaxSample, min(baseSample + SIMD32_WIDTH, maxSample) - receiveChannelMinSample)
				if minK > maxK do continue

				sum := SIMD_F32(0)
				for k in minK ..= maxK {
					kt := k - transmissionMinSample
					#no_bounds_check tSamples := SIMD_F32(transmissionImpulse[kt])
					kr := samples - k - receiveChannelMinSample
					kr0 := baseSample - k - receiveChannelMinSample
					krMask := simd.bit_and(simd.lanes_ge(kr, 0), simd.lanes_lt(kr, SIMD_I32(receiveChannelSampleCount)))
					#no_bounds_check rSamples := simd.masked_load(cast(^SIMD_F32)raw_data(receiveChannelImpulse[kr0:]), SIMD_F32(0), krMask)
					sum += tSamples * rSamples
				}
				#no_bounds_check dataPtr := cast(^SIMD_F32)raw_data(receiveDataLine[baseSample:])
				d := simd.masked_load(dataPtr, cast(SIMD_F32)0, sampleMask)
				d += sum
				simd.masked_store(dataPtr, d, sampleMask)
			}
		}
	}
}

convolve_frequency_domain :: proc(
	sampleCount, transmissionCount, receiveChannelCount: i32,
	scatter: Scatter,
	transmissionMinSamples, receiveChannelMinSamples, transmissionSampleCounts, receiveChannelSampleCounts: []i32,
	transmissionImpulses, receiveChannelImpulses, data: []f32,
) {
	utility.prof_scoped(#procedure)

	fourierWork := make_aligned([]f32, sampleCount, 16, context.allocator)
	convolutionData := make_aligned([]f32, sampleCount, 16, context.allocator)

	utility.prof_begin("Forward FFT")
	maxTransmissionSampleCount := slice.max(transmissionSampleCounts)
	maxReceiveChannelSampleCount := slice.max(receiveChannelSampleCounts)
	fftCount := pffft.adjust_n(auto_cast max(maxTransmissionSampleCount, maxReceiveChannelSampleCount))
	pffftSession := pffft.new_setup(fftCount, .REAL)
	assert(pffftSession != nil)
	defer pffft.destroy_setup(pffftSession)
	for transmissionIndex in 0 ..< transmissionCount {
		transmissionImpulse := raw_data(transmissionImpulses[transmissionIndex * auto_cast sampleCount:][:sampleCount])
		pffft.transform(pffftSession, transmissionImpulse, transmissionImpulse, raw_data(fourierWork), .FORWARD)
	}
	for receiveChannelIndex in 0 ..< receiveChannelCount {
		receiveChannelImpulse := raw_data(receiveChannelImpulses[receiveChannelIndex * auto_cast sampleCount:][:sampleCount])
		pffft.transform(pffftSession, receiveChannelImpulse, receiveChannelImpulse, raw_data(fourierWork), .FORWARD)
	}
	utility.prof_end()

	utility.prof_begin("Inverse FFT")
	for transmissionIndex in 0 ..< transmissionCount {
		transmissionMinSample := transmissionMinSamples[transmissionIndex]
		transmissionSampleCount := transmissionSampleCounts[transmissionIndex]
		transmissionMaxSample := transmissionMinSample + transmissionSampleCount - 1
		transmissionImpulse := transmissionImpulses[transmissionIndex * auto_cast sampleCount:][:sampleCount]
		for receiveChannelIndex in 0 ..< receiveChannelCount {
			receiveChannelMinSample := receiveChannelMinSamples[receiveChannelIndex]
			receiveChannelSampleCount := receiveChannelSampleCounts[receiveChannelIndex]
			receiveChannelMaxSample := receiveChannelMinSample + receiveChannelSampleCount - 1
			receiveChannelImpulse := receiveChannelImpulses[receiveChannelIndex * auto_cast sampleCount:][:sampleCount]

			minSample := transmissionMinSample + receiveChannelMinSample
			maxSample := transmissionMaxSample + receiveChannelMaxSample + 1
			minSample = max(minSample, 0)
			maxSample = min(maxSample, auto_cast sampleCount)
			if minSample >= maxSample do continue

			#no_bounds_check receiveDataLine := data[(receiveChannelIndex + (transmissionIndex * receiveChannelCount)) * auto_cast sampleCount:][:sampleCount]

			slice.zero(convolutionData)
			pffft.zconvolve_accumulate(
				pffftSession,
				raw_data(transmissionImpulse),
				raw_data(receiveChannelImpulse),
				raw_data(convolutionData),
				scatter.amplitude / f32(fftCount),
			)

			utility.prof_begin("Inverse Fourier Transform")
			pffft.transform(pffftSession, raw_data(convolutionData), raw_data(convolutionData), raw_data(fourierWork), .BACKWARD)
			utility.prof_end()

			for sample := minSample; sample < maxSample; sample += 1 {
				receiveDataLine[sample] += convolutionData[sample - minSample]
			}
		}
	}
	utility.prof_end()
}

ImpulseResponse :: struct {
	rect:  [4]f32,
	scale: f32,
}

SIMD32_WIDTH :: 16
SIMD_F32 :: #simd[SIMD32_WIDTH]f32
SIMD_I32 :: #simd[SIMD32_WIDTH]i32
SIMD_U32 :: #simd[SIMD32_WIDTH]u32

get_spatial_impulse_response :: proc(
	speedOfSound, samplingFrequency: f32,
	element: RectangularElement,
	scatter: Scatter,
) -> (
	impulseResponse: ImpulseResponse,
) {
	rotationAngle := linalg.quaternion_between_two_vector3(element.normal, [3]f32{0, 0, 1})
	rotation := linalg.matrix4_from_quaternion(rotationAngle)
	transform := rotation * linalg.matrix4_translate(element.position)
	scatterPosition := linalg.matrix_mul_vector(transform, [4]f32{**scatter.position, 1}).xyz
	dieProjection := linalg.abs(element.size * scatterPosition.xy)
	distance := linalg.length(scatterPosition)
	t0 := distance / speedOfSound
	dt1 := linalg.min_single(dieProjection) / distance / speedOfSound
	dt2 := linalg.max_single(dieProjection) / distance / speedOfSound

	rectTimes := t0 + 0.5 * (dt1 * [4]f32{-1, +1, -1, +1} + dt2 * [4]f32{-1, -1, +1, +1}) + element.delay
	impulseResponse.rect = rectTimes * samplingFrequency
	dt := 1 / samplingFrequency

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
