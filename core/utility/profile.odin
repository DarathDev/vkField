package vkField_utility

import "core:fmt"
import "core:mem"
import "core:prof/spall"
import "core:sync"

Profiling_Mode_Type :: enum {
	None      = 0,
	Custom    = 1,
	All_Funcs = 2,
}

PROF_MODE :: Profiling_Mode_Type(#config(PROF_MODE, 0))

when PROF_MODE != .None {
	spall_ctx: spall.Context

	@(thread_local)
	spall_buffer: spall.Buffer
	@(thread_local)
	buffer_backing: []u8
	@(thread_local)
	prof_allocator: mem.Allocator
}

when PROF_MODE == .All_Funcs {

	@(instrumentation_enter)
	spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		if spall_buffer.data == nil do return
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		if spall_buffer.data == nil do return
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}

}

// Call once at the very start of the main thread
@(deferred_none = prof_deinit)
prof_init :: proc(name: string, allocator := context.allocator) {
	when PROF_MODE != .None {
		spall_ctx = spall.context_create(fmt.tprintf("%s.spall", name))
	}
}

prof_deinit :: proc() {
	defer when PROF_MODE != .None {
		spall.context_destroy(&spall_ctx)
	}
}

// Call once per spawned thread to allocate the thread-local buffer
@(deferred_none = prof_thread_deinit)
prof_thread_init :: proc(allocator := context.allocator) {
	when PROF_MODE != .None {
		prof_allocator = allocator
		buffer_backing = make([]u8, spall.BUFFER_DEFAULT_SIZE, allocator)
		spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
	}
}

// Call once at the very end of each spawned thread
prof_thread_deinit :: proc() {
	defer when PROF_MODE != .None {
		spall.buffer_destroy(&spall_ctx, &spall_buffer)
		delete(buffer_backing, prof_allocator)
	}
}

// Create a scoped event which automatically ends itself at the end of the caller's scope.
@(deferred_none = prof_end)
prof_scoped :: #force_inline proc(label: string, loc := #caller_location) {
	prof_begin(label, loc)
}

// A lower level profiling primitive to be called at the start of a section
prof_begin :: proc(label: string, loc := #caller_location) {
	when PROF_MODE != .None {
		spall._buffer_begin(&spall_ctx, &spall_buffer, label, "", loc)
	}
}

// A lower level profiling primitive to be called at the end of a section
prof_end :: proc() {
	when PROF_MODE != .None {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}
}
