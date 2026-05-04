package vkfield

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "vkField:utility"
import vkField_vk "vkField:vulkan"

@(export)
create_vulkan_simulator_c :: proc "c" (simulator: ^^Simulator, cLogger: cLogProc = nil, loggerUserData: rawptr = nil) -> (ok := true) {
	if !vkField_vk.VKFIELD_VULKAN_INITIALIZED {
		vkField_vk.initialize()
	}
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, loggerUserData)
	simulator^ = new(Simulator)
	simulator^^, ok = utility.is_ok(create_vulkan_simulator())
	return
}

@(export)
destroy_vulkan_simulator_c :: proc "c" (simulator: ^Simulator, cLogger: cLogProc = nil, loggerUserData: rawptr = nil) -> (ok := true) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, loggerUserData)
	utility.check(simulator != nil) or_return
	if vkSimulator, vkSimOk := simulator.(vkSimulator); vkSimOk {
		destroy_vulkan_simulator(&vkSimulator)
	}
	return
}

@(export)
plan_simulation_c :: proc "c" (
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmitElements: ^Element,
	receiveElements: ^Element,
	scatters: ^Scatter,
	cLogger: cLogProc = nil,
	loggerUserData: rawptr = nil,
) -> (
	ok := true,
) {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, loggerUserData)
	return plan_simulation(
		simulator,
		settings,
		slice.from_ptr(transmitElements, int(settings.transmitElementCount)),
		slice.from_ptr(receiveElements, int(settings.receiveElementCount)),
		slice.from_ptr(scatters, int(settings.scatterCount)),
	)
}

@(export)
simulate_c :: proc "c" (
	simulator: ^Simulator,
	settings: ^SimulationSettings,
	transmitElements: [^]Element,
	receiveElements: [^]Element,
	scatters: [^]Scatter,
	pulseEcho: [^]f32,
	cLogger: cLogProc = nil,
	loggerUserData: rawptr = nil,
) -> bool {
	context = runtime.default_context()
	context.logger = c_logger(context.logger, cLogger, loggerUserData)
	data, ok := simulate(
		simulator^,
		settings,
		transmitElements[:settings.transmitElementCount],
		receiveElements[:settings.receiveElementCount],
		scatters[:settings.scatterCount],
	)
	copy(pulseEcho[:len(data)], data)
	delete(data)
	free_all(context.temp_allocator)
	return ok
}

cLogProc :: #type proc "c" (pUserData: rawptr, string: cstring)
@(private = "file")
c_logger :: proc(l: log.Logger, c: cLogProc, pUserData: rawptr) -> log.Logger {
	c_logger_data :: struct {
		wrappedLogger: log.Logger,
		cLogProc:      cLogProc,
		pUserData:     rawptr,
	}
	c_logger_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, locations := #caller_location) {
		data := cast(^c_logger_data)data
		if (data.cLogProc != nil) {
			data.cLogProc(data.pUserData, strings.clone_to_cstring(text, context.temp_allocator))
		}
		data.wrappedLogger.procedure(data.wrappedLogger.data, level, text, options, locations)
	}

	logger_data := new(c_logger_data, context.allocator)
	logger_data.wrappedLogger = context.logger
	logger_data.cLogProc = c
	logger_data.pUserData = pUserData
	return log.Logger {
		data = logger_data,
		lowest_level = logger_data.wrappedLogger.lowest_level,
		options = logger_data.wrappedLogger.options,
		procedure = c_logger_proc,
	}
}
