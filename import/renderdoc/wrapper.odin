package renderdoc

import "core:c"
import "core:dynlib"
import "core:log"
import "core:math"
import "core:strings"
import "core:sys/posix"
import "core:sys/windows"
import "core:time"

LOAD_RENDERDOC :: #config(LOAD_RENDERDOC, true)

Api :: distinct rawptr
LoadedVersion: Version

CaptureOptionValue :: union {
	u32,
	f32,
}

// Utility to load RenderDoc API.
// Pass version to request, and set remove_hooks = true to immediately remove RenderDoc's hooks upon loading.
//
// THREAD SAFETY WARNING:
// `load_api` is NOT thread-safe. It must be called once as early as possible during application startup
// on the main thread before any graphics API initialization or work occurs.
load_api :: proc(version: Version = ._7_0, removeHooks := false) -> (lib: dynlib.Library, rdocApi: Api, ok: bool) {
	when LOAD_RENDERDOC {
		when ODIN_OS == .Linux {
			RTLD_NOLOAD :: cast(posix.RTLD_Flag_Bits)2
			handle := posix.dlopen("librenderdoc.so", posix.RTLD_LOCAL + {RTLD_NOLOAD, .NOW})
		} else {
			handle := windows.GetModuleHandleA("renderdoc.dll")
		}

		// NOTE: renderdoc not attached
		if handle == nil do return nil, nil, false

		GET_API_SYMBOL :: "RENDERDOC_GetAPI"
		symbolPtr, found := dynlib.symbol_address(dynlib.Library(handle), GET_API_SYMBOL)
		if !found {
			log.errorf("renderdoc: failed to load symbol %v: %v", GET_API_SYMBOL, dynlib.last_error())
			return nil, nil, false
		}

		getApi: GetAPI = cast(GetAPI)symbolPtr
		getApi(version, auto_cast &rdocApi)
		LoadedVersion = version

		if removeHooks do remove_hooks_internal(rdocApi)

		return dynlib.Library(handle), rdocApi, true
	}
	return nil, nil, false
}

// Utility to unload RenderDoc library handle.
//
// THREAD SAFETY WARNING:
// `unload_api` is NOT thread-safe. It should only be called on shutdown after all graphics API tasks have ended.
@(disabled = !LOAD_RENDERDOC)
unload_api :: proc(lib: dynlib.Library) {
	if lib == nil do return

	didUnload := dynlib.unload_library(lib)
	if !didUnload {
		log.errorf("error unloading lib %v, reason: %v", lib, dynlib.last_error())
		return
	}

	#no_type_assert LoadedVersion = Version(0)
}

// Sets an option that controls how RenderDoc behaves on capture.
//
// Returns true if the option and value are valid
// Returns false if either is invalid and the option is unchanged
set_capture_option :: proc(rdocApi: Api, opt: CaptureOption, val: $T) -> (ok: bool) where T == u32 || T == f32 {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		when T == u32 {
			return rdocApiInternal.SetCaptureOptionU32(opt, val) == 1
		} else when T == f32 {
			return rdocApiInternal.SetCaptureOptionF32(opt, val) == 1
		}
	}
	return false
}

set_capture_option_value :: proc(rdocApi: Api, opt: CaptureOption, val: CaptureOptionValue) -> (ok: bool) {
	switch v in val {
	case u32:
		return set_capture_option(rdocApi, opt, v)
	case f32:
		return set_capture_option(rdocApi, opt, v)
	}
	return false
}

// Gets the current value of an option as a u32 or f32
get_capture_option :: proc(rdocApi: Api, opt: CaptureOption, $T: typeid) -> (val: T, ok: bool) where T == u32 || T == f32 {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return {}, false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		when T == u32 {
			res := rdocApiInternal.GetCaptureOptionU32(opt)
			if res == 0xffffffff do return 0, false
			return res, true
		} else when T == f32 {
			res := rdocApiInternal.GetCaptureOptionF32(opt)
			if res == -math.F32_MAX do return 0, false
			return res, true
		}
	}
	return {}, false
}

get_capture_option_u32 :: proc(rdocApi: Api, opt: CaptureOption) -> (val: u32, ok: bool) {
	return get_capture_option(rdocApi, opt, u32)
}

get_capture_option_f32 :: proc(rdocApi: Api, opt: CaptureOption) -> (val: f32, ok: bool) {
	return get_capture_option(rdocApi, opt, f32)
}

// Sets which key or keys can be used to toggle focus between multiple windows
//
// If keys is NULL or num is 0, toggle keys will be disabled
@(disabled = !LOAD_RENDERDOC)
set_focus_toggle_keys :: proc(rdocApi: Api, keys: []InputButton) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.SetFocusToggleKeys(raw_data(keys), cast(i32)len(keys))
}

// Sets which key or keys can be used to capture the next frame
//
// If keys is NULL or num is 0, captures keys will be disabled
@(disabled = !LOAD_RENDERDOC)
set_capture_keys :: proc(rdocApi: Api, keys: []InputButton) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.SetCaptureKeys(raw_data(keys), cast(i32)len(keys))
}

// returns the overlay bits that have been set
get_overlay_bits :: proc(rdocApi: Api) -> (bits: OverlayBits, ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return {}, false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return cast(OverlayBits)rdocApiInternal.GetOverlayBits(), true
	}
	return {}, false
}

// sets the overlay bits with an and & or mask
@(disabled = !LOAD_RENDERDOC)
mask_overlay_bits :: proc(rdocApi: Api, andMask: u32, orMask: u32) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.MaskOverlayBits(andMask, orMask)
}

// Private helper to remove RenderDoc hooks immediately upon API loading.
@(disabled = !LOAD_RENDERDOC, private = "file")
remove_hooks_internal :: proc(rdocApi: Api) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.RemoveHooks()
}

// This function will unload RenderDoc's crash handler.
@(disabled = !LOAD_RENDERDOC)
unload_crash_handler :: proc(rdocApi: Api) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.UnloadCrashHandler()
}

// Sets the capture file path template
@(disabled = !LOAD_RENDERDOC)
set_capture_file_path_template :: proc(rdocApi: Api, pathTemplate: string) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	cTemplate := strings.clone_to_cstring(pathTemplate, context.temp_allocator)
	rdocApiInternal.SetCaptureFilePathTemplate(cTemplate)
}

// returns the current capture path template as a string
get_capture_file_path_template :: proc(rdocApi: Api) -> (pathTemplate: string, ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return "", false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		res := rdocApiInternal.GetCaptureFilePathTemplate()
		if res == nil do return "", false
		return string(res), true
	}
	return "", false
}

// returns the number of captures that have been made
get_num_captures :: proc(rdocApi: Api) -> (count: u32, ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return 0, false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return rdocApiInternal.GetNumCaptures(), true
	}
	return 0, false
}

// Low-level binding wrapper to query capture details by index
get_capture :: proc(rdocApi: Api, idx: u32, filenameCstr: cstring = nil, pathLength: ^u32 = nil, timeStamp: ^u64 = nil) -> (ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return rdocApiInternal.GetCapture(idx, filenameCstr, pathLength, timeStamp) == 1
	}
	return false
}

// High-level wrapper returning string and time.Time
get_capture_info :: proc(rdocApi: Api, idx: u32, allocator := context.temp_allocator) -> (filename: string, timestamp: time.Time, ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return "", {}, false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		pathLen: u32
		ts: u64
		if rdocApiInternal.GetCapture(idx, nil, &pathLen, &ts) == 0 do return "", {}, false
		t := time.unix(i64(ts), 0)
		if pathLen == 0 do return "", t, true
		buf := make([]byte, pathLen, allocator)
		if rdocApiInternal.GetCapture(idx, cstring(raw_data(buf)), &pathLen, &ts) == 1 {
			return string(buf[:max(0, pathLen - 1)]), time.unix(i64(ts), 0), true
		}
	}
	return "", {}, false
}

// Sets the comments associated with a capture file
@(disabled = !LOAD_RENDERDOC)
set_capture_file_comments :: proc(rdocApi: Api, filePath: string, comments: string) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._2_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	cFilePath := strings.clone_to_cstring(filePath, context.temp_allocator) if len(filePath) > 0 else nil
	cComments := strings.clone_to_cstring(comments, context.temp_allocator)
	rdocApiInternal.SetCaptureFileComments(cFilePath, cComments)
}

// returns true if the RenderDoc UI is connected to this application
is_target_control_connected :: proc(rdocApi: Api) -> (connected: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return rdocApiInternal.IsTargetControlConnected() == 1
	}
	return false
}

// Launches the Replay UI associated with the RenderDoc library
launch_replay_ui :: proc(rdocApi: Api, connectTargetControl: bool, cmdLine: string = "") -> (pid: u32, ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return 0, false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		cCmdLine := strings.clone_to_cstring(cmdLine, context.temp_allocator) if len(cmdLine) > 0 else nil
		pidRes := rdocApiInternal.LaunchReplayUI(u32(connectTargetControl ? 1 : 0), cCmdLine)
		if pidRes == 0 do return 0, false
		return pidRes, true
	}
	return 0, false
}

// Helper to launch or bring up the RenderDoc Replay UI.
// If target control is connected to this application, it requests the UI to show itself;
// otherwise, it launches a new instance of the Replay UI.
launch_or_show_replay_ui :: proc(rdocApi: Api, cmdLine: string = "") -> (pid: u32, ok: bool) {
	if is_target_control_connected(rdocApi) {
		shown := show_replay_ui(rdocApi)
		return 0, shown
	}
	return launch_replay_ui(rdocApi, true, cmdLine)
}

// Returns the actual API version returned by RenderDoc
get_api_version :: proc(rdocApi: Api) -> (major: int, minor: int, patch: int, ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return 0, 0, 0, false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		cMajor, cMinor, cPatch: c.int
		rdocApiInternal.GetAPIVersion(&cMajor, &cMinor, &cPatch)
		return int(cMajor), int(cMinor), int(cPatch), true
	}
	return 0, 0, 0, false
}

// Requests that the replay UI show itself
show_replay_ui :: proc(rdocApi: Api) -> (ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return false
		assert(LoadedVersion >= ._5_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return rdocApiInternal.ShowReplayUI() == 1
	}
	return false
}

@(disabled = !LOAD_RENDERDOC)
set_active_window :: proc(rdocApi: Api, device: DevicePointer, wndHandle: WindowHandle) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.SetActiveWindow(device, wndHandle)
}

@(disabled = !LOAD_RENDERDOC)
trigger_capture :: proc(rdocApi: Api) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.TriggerCapture()
}

@(disabled = !LOAD_RENDERDOC)
trigger_multi_frame_capture :: proc(rdocApi: Api, numFrames: u32) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._1_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.TriggerMultiFrameCapture(numFrames)
}

@(disabled = !LOAD_RENDERDOC)
start_frame_capture :: proc(rdocApi: Api, device: DevicePointer, wndHandle: WindowHandle) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._0_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	rdocApiInternal.StartFrameCapture(device, wndHandle)
}

is_frame_capturing :: proc(rdocApi: Api) -> (capturing: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return rdocApiInternal.IsFrameCapturing() == 1
	}
	return false
}

end_frame_capture :: proc(rdocApi: Api, device: DevicePointer, wndHandle: WindowHandle) -> (ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return false
		assert(LoadedVersion >= ._0_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return rdocApiInternal.EndFrameCapture(device, wndHandle) == 1
	}
	return false
}

discard_frame_capture :: proc(rdocApi: Api, device: DevicePointer, wndHandle: WindowHandle) -> (ok: bool) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return false
		assert(LoadedVersion >= ._4_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		return rdocApiInternal.DiscardFrameCapture(device, wndHandle) == 1
	}
	return false
}

@(disabled = !LOAD_RENDERDOC)
set_capture_title :: proc(rdocApi: Api, title: string) {
	if rdocApi == nil do return
	assert(LoadedVersion >= ._6_0)
	rdocApiInternal := cast(^API_1_7_0)rdocApi
	cTitle := strings.clone_to_cstring(title, context.temp_allocator)
	rdocApiInternal.SetCaptureTitle(cTitle)
}

set_object_annotation :: proc(
	rdocApi: Api,
	device: DevicePointer,
	object: rawptr,
	key: string,
	valueType: AnnotationType,
	valueVectorWidth: u32,
	value: ^AnnotationValue,
) -> (
	result: u32,
	ok: bool,
) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return 0, false
		assert(LoadedVersion >= ._7_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		cKey := strings.clone_to_cstring(key, context.temp_allocator)
		res := rdocApiInternal.SetObjectAnnotation(device, object, cKey, valueType, valueVectorWidth, value)
		return res, res == 0
	}
	return 0, false
}

set_command_annotation :: proc(
	rdocApi: Api,
	device: DevicePointer,
	queueOrCommandBuffer: rawptr,
	key: string,
	valueType: AnnotationType,
	valueVectorWidth: u32,
	value: ^AnnotationValue,
) -> (
	result: u32,
	ok: bool,
) {
	when LOAD_RENDERDOC {
		if rdocApi == nil do return 0, false
		assert(LoadedVersion >= ._7_0)
		rdocApiInternal := cast(^API_1_7_0)rdocApi
		cKey := strings.clone_to_cstring(key, context.temp_allocator)
		res := rdocApiInternal.SetCommandAnnotation(device, queueOrCommandBuffer, cKey, valueType, valueVectorWidth, value)
		return res, res == 0
	}
	return 0, false
}
