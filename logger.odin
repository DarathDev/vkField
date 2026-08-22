package vkField_build

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:terminal/ansi"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

LogType :: enum {
	Info,
	Command,
	Generate,
	Warning,
	Error,
}

@(thread_local)
build_local_tz: Maybe(^datetime.TZ_Region)

get_build_local_tz :: proc() -> (tz: ^datetime.TZ_Region, ok := true) {
	tz = build_local_tz.? or_else timezone.region_load("local") or_return
	build_local_tz = tz
	return
}

append_local_time_header :: proc(buf: ^strings.Builder) -> (ok := true) {
	now := time.now()
	defer log.do_time_header({.Date, .Time}, buf, now)

	now_dt := time.time_to_datetime(now) or_return
	local_tz := get_build_local_tz() or_return
	local_dt := timezone.datetime_to_tz(now_dt, local_tz) or_return
	now = time.datetime_to_time(local_dt) or_return
	return
}

build_log :: proc(h: ^os.File, type: LogType, text: string) {
	RESET :: ansi.CSI + ansi.RESET + ansi.SGR

	backing: [1024]byte
	buf := strings.builder_from_bytes(backing[:])

	color := RESET
	typeString := ""
	switch type {
	case .Info:
		color = ansi.CSI + ansi.FG_MAGENTA + ansi.SGR
		typeString = "INFO"
	case .Command:
		color = ansi.CSI + ansi.FG_BLUE + ansi.SGR
		typeString = "COMMAND"
	case .Generate:
		color = ansi.CSI + ansi.FG_GREEN + ansi.SGR
		typeString = "GENERATE"
	case .Warning:
		color = ansi.CSI + ansi.FG_YELLOW + ansi.SGR
		typeString = "WARNING"
	case .Error:
		color = ansi.CSI + ansi.FG_RED + ansi.SGR
		typeString = "ERROR"
	}

	isTerminal := terminal.is_terminal(h)
	isColored := isTerminal && terminal.color_enabled

	if isColored {
		fmt.sbprint(&buf, color)
	}
	fmt.sbprint(&buf, "[")
	fmt.sbprint(&buf, typeString)
	fmt.sbprint(&buf, "] ")

	when time.IS_SUPPORTED {
		append_local_time_header(&buf)
	}

	if isColored {
		fmt.sbprint(&buf, RESET)
	}
	fmt.sbprint(&buf, text)
	fmt.sbprint(&buf, "\n")

	os.write_string(h, strings.to_string(buf))
}
