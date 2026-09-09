/******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2015-2026 Baldur Karlsson
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 ******************************************************************************/
package renderdoc

// truncated version when only a uint64_t is available (e.g. Vulkan tags):
ShaderDebugMagicValue_truncated :: 0x48656670eab25520

// this is a magic value for vulkan user tags to indicate which dispatchable API objects are which
// for object annotations
APIObjectAnnotationHelper :: 0xfbb3b337b664d0ad

//////////////////////////////////////////////////////////////////////////////////////////////////
// RenderDoc capture options
//
CaptureOption :: enum i32 {
	// Allow the application to enable vsync
	//
	// Default - enabled
	//
	// 1 - The application can enable or disable vsync at will
	// 0 - vsync is force disabled
	AllowVSync                       = 0,

	// Allow the application to enable fullscreen
	//
	// Default - enabled
	//
	// 1 - The application can enable or disable fullscreen at will
	// 0 - fullscreen is force disabled
	AllowFullscreen                  = 1,

	// Record API debugging events and messages
	//
	// Default - disabled
	//
	// 1 - Enable built-in API debugging features and records the results into
	//     the capture, which is matched up with events on replay
	// 0 - no API debugging is forcibly enabled
	APIValidation                    = 2,
	DebugDeviceMode                  = 2, // deprecated name of this enum

	// Capture CPU callstacks for API events
	//
	// Default - disabled
	//
	// 1 - Enables capturing of callstacks
	// 0 - no callstacks are captured
	CaptureCallstacks                = 3,

	// When capturing CPU callstacks, only capture them from actions.
	// This option does nothing without the above option being enabled
	//
	// Default - disabled
	//
	// 1 - Only captures callstacks for actions.
	//     Ignored if CaptureCallstacks is disabled
	// 0 - Callstacks, if enabled, are captured for every event.
	CaptureCallstacksOnlyDraws       = 4,
	CaptureCallstacksOnlyActions     = 4,

	// Specify a delay in seconds to wait for a debugger to attach, after
	// creating or injecting into a process, before continuing to allow it to run.
	//
	// 0 indicates no delay, and the process will run immediately after injection
	//
	// Default - 0 seconds
	//
	DelayForDebugger                 = 5,

	// Verify buffer access. This includes checking the memory returned by a Map() call to
	// detect any out-of-bounds modification, as well as initialising buffers with undefined contents
	// to a marker value to catch use of uninitialised memory.
	//
	// NOTE: This option is only valid for OpenGL and D3D11. Explicit APIs such as D3D12 and Vulkan do
	// not do the same kind of interception & checking and undefined contents are really undefined.
	//
	// Default - disabled
	//
	// 1 - Verify buffer access
	// 0 - No verification is performed, and overwriting bounds may cause crashes or corruption in
	//     RenderDoc.
	VerifyBufferAccess               = 6,

	// The old name for eRENDERDOC_Option_VerifyBufferAccess was eRENDERDOC_Option_VerifyMapWrites.
	// This option now controls the filling of uninitialised buffers with 0xdddddddd which was
	// previously always enabled
	VerifyMapWrites                  = 6,

	// Hooks any system API calls that create child processes, and injects
	// RenderDoc into them recursively with the same options.
	//
	// Default - disabled
	//
	// 1 - Hooks into spawned child processes
	// 0 - Child processes are not hooked by RenderDoc
	HookIntoChildren                 = 7,

	// By default RenderDoc only includes resources in the final capture necessary
	// for that frame, this allows you to override that behaviour.
	//
	// Default - disabled
	//
	// 1 - all live resources at the time of capture are included in the capture
	//     and available for inspection
	// 0 - only the resources referenced by the captured frame are included
	RefAllResources                  = 8,

	// **NOTE**: As of RenderDoc v1.1 this option has been deprecated. Setting or
	// getting it will be ignored, to allow compatibility with older versions.
	// In v1.1 the option acts as if it's always enabled.
	//
	// By default RenderDoc skips saving initial states for resources where the
	// previous contents don't appear to be used, assuming that writes before
	// reads indicate previous contents aren't used.
	//
	// Default - disabled
	//
	// 1 - initial contents at the start of each captured frame are saved, even if
	//     they are later overwritten or cleared before being used.
	// 0 - unless a read is detected, initial contents will not be saved and will
	//     appear as black or empty data.
	SaveAllInitials                  = 9,

	// In APIs that allow for the recording of command lists to be replayed later,
	// RenderDoc may choose to not capture command lists before a frame capture is
	// triggered, to reduce overheads. This means any command lists recorded once
	// and replayed many times will not be available and may cause a failure to
	// capture.
	//
	// NOTE: This is only true for APIs where multithreading is difficult or
	// discouraged. Newer APIs like Vulkan and D3D12 will ignore this option
	// and always capture all command lists since the API is heavily oriented
	// around it and the overheads have been reduced by API design.
	//
	// 1 - All command lists are captured from the start of the application
	// 0 - Command lists are only captured if their recording begins during
	//     the period when a frame capture is in progress.
	CaptureAllCmdLists               = 10,

	// Mute API debugging output when the API validation mode option is enabled
	//
	// Default - enabled
	//
	// 1 - Mute any API debug messages from being displayed or passed through
	// 0 - API debugging is displayed as normal
	DebugOutputMute                  = 11,

	// Option to allow vendor extensions to be used even when they may be
	// incompatible with RenderDoc and cause corrupted replays or crashes.
	//
	// Default - inactive
	//
	// No values are documented, this option should only be used when absolutely
	// necessary as directed by a RenderDoc developer.
	AllowUnsupportedVendorExtensions = 12,

	// Define a soft memory limit which some APIs may aim to keep overhead under where
	// possible. Anything above this limit will where possible be saved directly to disk during
	// capture.
	// This will cause increased disk space use (which may cause a capture to fail if disk space is
	// exhausted) as well as slower capture times.
	//
	// Not all memory allocations may be deferred like this so it is not a guarantee of a memory
	// limit.
	//
	// Units are in MBs, suggested values would range from 200MB to 1000MB.
	//
	// Default - 0 Megabytes
	SoftMemoryLimit                  = 13,
}

// Sets an option that controls how RenderDoc behaves on capture.
//
// Returns 1 if the option and value are valid
// Returns 0 if either is invalid and the option is unchanged
SetCaptureOptionU32 :: proc "c" (opt: CaptureOption, val: u32) -> i32
SetCaptureOptionF32 :: proc "c" (opt: CaptureOption, val: f32) -> i32

// Gets the current value of an option as a uint32_t
//
// If the option is invalid, 0xffffffff is returned
GetCaptureOptionU32 :: proc "c" (opt: CaptureOption) -> u32

// Gets the current value of an option as a float
//
// If the option is invalid, -FLT_MAX is returned
GetCaptureOptionF32 :: proc "c" (opt: CaptureOption) -> f32

InputButton :: enum i32 {
	// '0' - '9' matches ASCII values
	_0           = 48,
	_1           = 49,
	_2           = 50,
	_3           = 51,
	_4           = 52,
	_5           = 53,
	_6           = 54,
	_7           = 55,
	_8           = 56,
	_9           = 57,

	// 'A' - 'Z' matches ASCII values
	A            = 65,
	B            = 66,
	C            = 67,
	D            = 68,
	E            = 69,
	F            = 70,
	G            = 71,
	H            = 72,
	I            = 73,
	J            = 74,
	K            = 75,
	L            = 76,
	M            = 77,
	N            = 78,
	O            = 79,
	P            = 80,
	Q            = 81,
	R            = 82,
	S            = 83,
	T            = 84,
	U            = 85,
	V            = 86,
	W            = 87,
	X            = 88,
	Y            = 89,
	Z            = 90,

	// leave the rest of the ASCII range free
	// in case we want to use it later
	NonPrintable = 256,
	Divide       = 257,
	Multiply     = 258,
	Subtract     = 259,
	Plus         = 260,
	F1           = 261,
	F2           = 262,
	F3           = 263,
	F4           = 264,
	F5           = 265,
	F6           = 266,
	F7           = 267,
	F8           = 268,
	F9           = 269,
	F10          = 270,
	F11          = 271,
	F12          = 272,
	Home         = 273,
	End          = 274,
	Insert       = 275,
	Delete       = 276,
	PageUp       = 277,
	PageDn       = 278,
	Backspace    = 279,
	Tab          = 280,
	PrtScrn      = 281,
	Pause        = 282,
	Max          = 283,
}

// Sets which key or keys can be used to toggle focus between multiple windows
//
// If keys is NULL or num is 0, toggle keys will be disabled
SetFocusToggleKeys :: proc "c" (keys: ^InputButton, num: i32)

// Sets which key or keys can be used to capture the next frame
//
// If keys is NULL or num is 0, captures keys will be disabled
SetCaptureKeys :: proc "c" (keys: ^InputButton, num: i32)

OverlayBits :: enum i32 {
	// This single bit controls whether the overlay is enabled or disabled globally
	Enabled     = 1,

	// Show the average framerate over several seconds as well as min/max
	FrameRate   = 2,

	// Show the current frame number
	FrameNumber = 4,

	// Show a list of recent captures, and how many captures have been made
	CaptureList = 8,

	// Default values for the overlay mask
	Default     = 15,

	// Enable all bits
	All         = 134217727,

	// Disable all bits
	None        = 0,
}

// returns the overlay bits that have been set
GetOverlayBits :: proc "c" () -> u32

// sets the overlay bits with an and & or mask
MaskOverlayBits :: proc "c" (And: u32, Or: u32)

// this function will attempt to remove RenderDoc's hooks in the application.
//
// Note: that this can only work correctly if done immediately after
// the module is loaded, before any API work happens. RenderDoc will remove its
// injected hooks and shut down. Behaviour is undefined if this is called
// after any API functions have been called, and there is still no guarantee of
// success.
RemoveHooks :: proc "c" ()

// DEPRECATED: compatibility for code compiled against pre-1.4.1 headers.
Shutdown :: RemoveHooks

// This function will unload RenderDoc's crash handler.
//
// If you use your own crash handler and don't want RenderDoc's handler to
// intercede, you can call this function to unload it and any unhandled
// exceptions will pass to the next handler.
UnloadCrashHandler :: proc "c" ()

// Sets the capture file path template
//
// pathtemplate is a UTF-8 string that gives a template for how captures will be named
// and where they will be saved.
//
// Any extension is stripped off the path, and captures are saved in the directory
// specified, and named with the filename and the frame number appended. If the
// directory does not exist it will be created, including any parent directories.
//
// If pathtemplate is NULL, the template will remain unchanged
//
// Example:
//
// SetCaptureFilePathTemplate("my_captures/example");
//
// Capture #1 -> my_captures/example_frame123.rdc
// Capture #2 -> my_captures/example_frame456.rdc
SetCaptureFilePathTemplate :: proc "c" (pathtemplate: cstring)

// returns the current capture path template, see SetCaptureFileTemplate above, as a UTF-8 string
GetCaptureFilePathTemplate :: proc "c" () -> cstring

// DEPRECATED: compatibility for code compiled against pre-1.1.2 headers.
SetLogFilePathTemplate :: SetCaptureFilePathTemplate
GetLogFilePathTemplate :: GetCaptureFilePathTemplate

// returns the number of captures that have been made
GetNumCaptures :: proc "c" () -> u32

// This function returns the details of a capture, by index. New captures are added
// to the end of the list.
//
// filename will be filled with the absolute path to the capture file, as a UTF-8 string
// pathlength will be written with the length in bytes of the filename string
// timestamp will be written with the time of the capture, in seconds since the Unix epoch
//
// Any of the parameters can be NULL and they'll be skipped.
//
// The function will return 1 if the capture index is valid, or 0 if the index is invalid
// If the index is invalid, the values will be unchanged
//
// Note: when captures are deleted in the UI they will remain in this list, so the
// capture path may not exist anymore.
GetCapture :: proc "c" (idx: u32, filename: cstring, pathlength: ^u32, timestamp: ^u64) -> u32

// Sets the comments associated with a capture file. These comments are displayed in the
// UI program when opening.
//
// filePath should be a path to the capture file to add comments to. If set to NULL or ""
// the most recent capture file created made will be used instead.
// comments should be a NULL-terminated UTF-8 string to add as comments.
//
// Any existing comments will be overwritten.
SetCaptureFileComments :: proc "c" (filePath: cstring, comments: cstring)

// returns 1 if the RenderDoc UI is connected to this application, 0 otherwise
IsTargetControlConnected :: proc "c" () -> u32

// DEPRECATED: compatibility for code compiled against pre-1.1.1 headers.
// This was renamed to IsTargetControlConnected in API 1.1.1, the old typedef is kept here for
// backwards compatibility with old code, it is castable either way since it's ABI compatible
// as the same function pointer type.
IsRemoteAccessConnected :: IsTargetControlConnected

// This function will launch the Replay UI associated with the RenderDoc library injected
// into the running application.
//
// if connectTargetControl is 1, the Replay UI will be launched with a command line parameter
// to connect to this application
// cmdline is the rest of the command line, as a UTF-8 string. E.g. a captures to open
// if cmdline is NULL, the command line will be empty.
//
// returns the PID of the replay UI if successful, 0 if not successful.
LaunchReplayUI :: proc "c" (connectTargetControl: u32, cmdline: cstring) -> u32

// RenderDoc can return a higher version than requested if it's backwards compatible,
// this function returns the actual version returned. If a parameter is NULL, it will be
// ignored and the others will be filled out.
GetAPIVersion :: proc "c" (major: ^i32, minor: ^i32, patch: ^i32)

// Requests that the replay UI show itself (if hidden or not the current top window). This can be
// used in conjunction with IsTargetControlConnected and LaunchReplayUI to intelligently handle
// showing the UI after making a capture.
//
// This will return 1 if the request was successfully passed on, though it's not guaranteed that
// the UI will be on top in all cases depending on OS rules. It will return 0 if there is no current
// target control connection to make such a request, or if there was another error
ShowReplayUI :: proc "c" () -> u32

// A device pointer is a pointer to the API's root handle.
//
// This would be an ID3D11Device, HGLRC/GLXContext, ID3D12Device, etc
DevicePointer :: rawptr

// A window handle is the OS's native window handle
//
// This would be an HWND, GLXDrawable, etc
WindowHandle :: rawptr

// This sets the RenderDoc in-app overlay in the API/window pair as 'active' and it will
// respond to keypresses. Neither parameter can be NULL
SetActiveWindow :: proc "c" (device: DevicePointer, wndHandle: WindowHandle)

// capture the next frame on whichever window and API is currently considered active
TriggerCapture :: proc "c" ()

// capture the next N frames on whichever window and API is currently considered active
TriggerMultiFrameCapture :: proc "c" (numFrames: u32)

// Immediately starts capturing API calls on the specified device pointer and window handle.
//
// If there is no matching thing to capture (e.g. no supported API has been initialised),
// this will do nothing.
//
// The results are undefined (including crashes) if two captures are started overlapping,
// even on separate devices and/oror windows.
StartFrameCapture :: proc "c" (device: DevicePointer, wndHandle: WindowHandle)

// Returns whether or not a frame capture is currently ongoing anywhere.
//
// This will return 1 if a capture is ongoing, and 0 if there is no capture running
IsFrameCapturing :: proc "c" () -> u32

// Ends capturing immediately.
//
// This will return 1 if the capture succeeded, and 0 if there was an error capturing.
EndFrameCapture :: proc "c" (device: DevicePointer, wndHandle: WindowHandle) -> u32

// Ends capturing immediately and discard any data stored without saving to disk.
//
// This will return 1 if the capture was discarded, and 0 if there was an error or no capture
// was in progress
DiscardFrameCapture :: proc "c" (device: DevicePointer, wndHandle: WindowHandle) -> u32

// Only valid to be called between a call to StartFrameCapture and EndFrameCapture. Gives a custom
// title to the capture produced which will be displayed in the UI.
//
// If multiple captures are ongoing, this title will be applied to the first capture to end after
// this call. The second capture to end will have no title, unless this function is called again.
//
// Calling this function has no effect if no capture is currently running, and if it is called
// multiple times only the last title will be used.
SetCaptureTitle :: proc "c" (title: cstring)

// the type of an annotation value, or Empty to delete an annotation
AnnotationType :: enum i32 {
	Empty         = 0,
	Bool          = 1,
	Int32         = 2,
	UInt32        = 3,
	Int64         = 4,
	UInt64        = 5,
	Float         = 6,
	Double        = 7,
	String        = 8,
	APIObject     = 9,
	AnnotationMax = 2147483647,
}

// a union with vector annotation value data
AnnotationVectorValue :: struct #raw_union {
	boolean: [4]bool,
	int32:   [4]i32,
	int64:   [4]i64,
	uint32:  [4]u32,
	uint64:  [4]u64,
	float32: [4]f32,
	float64: [4]f64,
}

// a union with scalar annotation value data
AnnotationValue :: struct #raw_union {
	boolean:   bool,
	int32:     i32,
	int64:     i64,
	uint32:    u32,
	uint64:    u64,
	float32:   f32,
	float64:   f64,
	vector:    AnnotationVectorValue,
	_string:   cstring,
	apiObject: rawptr,
}

// a struct for specifying a GL object, as we don't have pointers we can use so instead we specify a
// pointer to this struct giving both the type and the name
GLResourceReference :: struct {
	// this is the same GLenum identifier as passed to glObjectLabel
	identifier: u32,
	name:       u32,
}

// The device is specified in the same way as other API calls that take a RENDERDOC_DevicePointer
// to specify the device.
//
// The object or queue/commandbuffer will depend on the graphics API in question.
//
// Return value:
// 0 - The annotation was applied successfully.
// 1 - The device is unknown/invalid
// 2 - The device is valid but the annotation is not supported for API-specific reasons, such as an
//     unrecognised or invalid object or queue/commandbuffer
// 3 - The call is ill-formed or invalid e.g. empty is specified with a value pointer, or non-empty
//     is specified with a NULL value pointer
SetObjectAnnotation :: proc "c" (
	device: DevicePointer,
	object: rawptr,
	key: cstring,
	valueType: AnnotationType,
	valueVectorWidth: u32,
	value: ^AnnotationValue,
) -> u32
SetCommandAnnotation :: proc "c" (
	device: DevicePointer,
	queueOrCommandBuffer: rawptr,
	key: cstring,
	valueType: AnnotationType,
	valueVectorWidth: u32,
	value: ^AnnotationValue,
) -> u32

// RenderDoc uses semantic versioning (http://semver.org/).
//
// MAJOR version is incremented when incompatible API changes happen.
// MINOR version is incremented when functionality is added in a backwards-compatible manner.
// PATCH version is incremented when backwards-compatible bug fixes happen.
//
// Note that this means the API returned can be higher than the one you might have requested.
// e.g. if you are running against a newer RenderDoc that supports 1.0.1, it will be returned
// instead of 1.0.0. You can check this with the GetAPIVersion entry point
Version :: enum i32 {
	_0_0 = 10000, // RENDERDOC_API_1_0_0 = 1 00 00
	_0_1 = 10001, // RENDERDOC_API_1_0_1 = 1 00 01
	_0_2 = 10002, // RENDERDOC_API_1_0_2 = 1 00 02
	_1_0 = 10100, // RENDERDOC_API_1_1_0 = 1 01 00
	_1_1 = 10101, // RENDERDOC_API_1_1_1 = 1 01 01
	_1_2 = 10102, // RENDERDOC_API_1_1_2 = 1 01 02
	_2_0 = 10200, // RENDERDOC_API_1_2_0 = 1 02 00
	_3_0 = 10300, // RENDERDOC_API_1_3_0 = 1 03 00
	_4_0 = 10400, // RENDERDOC_API_1_4_0 = 1 04 00
	_4_1 = 10401, // RENDERDOC_API_1_4_1 = 1 04 01
	_4_2 = 10402, // RENDERDOC_API_1_4_2 = 1 04 02
	_5_0 = 10500, // RENDERDOC_API_1_5_0 = 1 05 00
	_6_0 = 10600, // RENDERDOC_API_1_6_0 = 1 06 00
	_7_0 = 10700, // RENDERDOC_API_1_7_0 = 1 07 00
}

// API version changelog:
//
// 1.0.0 - initial release
// 1.0.1 - Bugfix: IsFrameCapturing() was returning false for captures that were triggered
//         by keypress or TriggerCapture, instead of Start/EndFrameCapture.
// 1.0.2 - Refactor: Renamed eRENDERDOC_Option_DebugDeviceMode to eRENDERDOC_Option_APIValidation
// 1.1.0 - Add feature: TriggerMultiFrameCapture(). Backwards compatible with 1.0.x since the new
//         function pointer is added to the end of the struct, the original layout is identical
// 1.1.1 - Refactor: Renamed remote access to target control (to better disambiguate from remote
//         replay/remote server concept in replay UI)
// 1.1.2 - Refactor: Renamed "log file" in function names to just capture, to clarify that these
//         are captures and not debug logging files. This is the first API version in the v1.0
//         branch.
// 1.2.0 - Added feature: SetCaptureFileComments() to add comments to a capture file that will be
//         displayed in the UI program on load.
// 1.3.0 - Added feature: New capture option eRENDERDOC_Option_AllowUnsupportedVendorExtensions
//         which allows users to opt-in to allowing unsupported vendor extensions to function.
//         Should be used at the user's own risk.
//         Refactor: Renamed eRENDERDOC_Option_VerifyMapWrites to
//         eRENDERDOC_Option_VerifyBufferAccess, which now also controls initialisation to
//         0xdddddddd of uninitialised buffer contents.
// 1.4.0 - Added feature: DiscardFrameCapture() to discard a frame capture in progress and stop
//         capturing without saving anything to disk.
// 1.4.1 - Refactor: Renamed Shutdown to RemoveHooks to better clarify what is happening
// 1.4.2 - Refactor: Renamed 'draws' to 'actions' in callstack capture option.
// 1.5.0 - Added feature: ShowReplayUI() to request that the replay UI show itself if connected
// 1.6.0 - Added feature: SetCaptureTitle() which can be used to set a title for a
//         capture made with StartFrameCapture() or EndFrameCapture()
// 1.7.0 - Added feature: SetObjectAnnotation() / SetCommandAnnotation() for adding rich
//         annotations to objects and command streams
API_1_7_0 :: struct {
	GetAPIVersion:            GetAPIVersion,
	SetCaptureOptionU32:      SetCaptureOptionU32,
	SetCaptureOptionF32:      SetCaptureOptionF32,
	GetCaptureOptionU32:      GetCaptureOptionU32,
	GetCaptureOptionF32:      GetCaptureOptionF32,
	SetFocusToggleKeys:       SetFocusToggleKeys,
	SetCaptureKeys:           SetCaptureKeys,
	GetOverlayBits:           GetOverlayBits,
	MaskOverlayBits:          MaskOverlayBits,

	// Shutdown was renamed to RemoveHooks in 1.4.1.
	// These unions allow old code to continue compiling without changes
	using _:                  struct #raw_union {
		Shutdown:    Shutdown,
		RemoveHooks: RemoveHooks,
	},

	// Shutdown was renamed to RemoveHooks in 1.4.1.
	// These unions allow old code to continue compiling without changes
	UnloadCrashHandler:       UnloadCrashHandler,

	// Get/SetLogFilePathTemplate was renamed to Get/SetCaptureFilePathTemplate in 1.1.2.
	// These unions allow old code to continue compiling without changes
	using _:                  struct #raw_union {
		// deprecated name
		SetLogFilePathTemplate:     SetLogFilePathTemplate,

		// current name
		SetCaptureFilePathTemplate: SetCaptureFilePathTemplate,
	},
	using _:                  struct #raw_union {
		// deprecated name
		GetLogFilePathTemplate:     GetLogFilePathTemplate,

		// current name
		GetCaptureFilePathTemplate: GetCaptureFilePathTemplate,
	},
	GetNumCaptures:           GetNumCaptures,
	GetCapture:               GetCapture,
	TriggerCapture:           TriggerCapture,

	// IsRemoteAccessConnected was renamed to IsTargetControlConnected in 1.1.1.
	// This union allows old code to continue compiling without changes
	using _:                  struct #raw_union {
		// deprecated name
		IsRemoteAccessConnected:  IsRemoteAccessConnected,

		// current name
		IsTargetControlConnected: IsTargetControlConnected,
	},

	// IsRemoteAccessConnected was renamed to IsTargetControlConnected in 1.1.1.
	// This union allows old code to continue compiling without changes
	LaunchReplayUI:           LaunchReplayUI,
	SetActiveWindow:          SetActiveWindow,
	StartFrameCapture:        StartFrameCapture,
	IsFrameCapturing:         IsFrameCapturing,
	EndFrameCapture:          EndFrameCapture,

	// new function in 1.1.0
	TriggerMultiFrameCapture: TriggerMultiFrameCapture,

	// new function in 1.2.0
	SetCaptureFileComments:   SetCaptureFileComments,

	// new function in 1.4.0
	DiscardFrameCapture:      DiscardFrameCapture,

	// new function in 1.5.0
	ShowReplayUI:             ShowReplayUI,

	// new function in 1.6.0
	SetCaptureTitle:          SetCaptureTitle,

	// new functions in 1.7.0
	SetObjectAnnotation:      SetObjectAnnotation,
	SetCommandAnnotation:     SetCommandAnnotation,
}

API_1_0_0 :: API_1_7_0
API_1_0_1 :: API_1_7_0
API_1_0_2 :: API_1_7_0
API_1_1_0 :: API_1_7_0
API_1_1_1 :: API_1_7_0
API_1_1_2 :: API_1_7_0
API_1_2_0 :: API_1_7_0
API_1_3_0 :: API_1_7_0
API_1_4_0 :: API_1_7_0
API_1_4_1 :: API_1_7_0
API_1_4_2 :: API_1_7_0
API_1_5_0 :: API_1_7_0
API_1_6_0 :: API_1_7_0

//////////////////////////////////////////////////////////////////////////////////////////////////
// RenderDoc API entry point
//
// This entry point can be obtained via GetProcAddress/dlsym if RenderDoc is available.
//
// The name is the same as the typedef - "RENDERDOC_GetAPI"
//
// This function is not thread safe, and should not be called on multiple threads at once.
// Ideally, call this once as early as possible in your application's startup, before doing
// any API work, since some configuration functionality etc has to be done also before
// initialising any APIs.
//
// Parameters:
//   version is a single value from the RENDERDOC_Version above.
//
//   outAPIPointers will be filled out with a pointer to the corresponding struct of function
//   pointers.
//
// Returns:
//   1 - if the outAPIPointers has been filled with a pointer to the API struct requested
//   0 - if the requested version is not supported or the arguments are invalid.
//
GetAPI :: proc "c" (version: Version, outAPIPointers: ^rawptr) -> i32
