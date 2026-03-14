package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"

foreign import libc2 "system:c"

foreign libc2 {
	ioctl :: proc(fd: i32, request: u64, #c_vararg args: ..any) -> i32 ---
}

Winsize :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

EditorConfig :: struct {
	orig_termios: posix.termios,
	screenrows:   u16,
	screencols:   u16,
}


@(private = "file")
E: EditorConfig

@(private = "file")
abuf: [dynamic]byte

/* Helpers */
write_stdout :: proc(s: string) -> (n: int, err: os.Error) {
	return os.write(os.stdout, transmute([]u8)s)
}

posix_write_stdout :: proc "c" (s: string) {
	posix.write(posix.STDOUT_FILENO, raw_data(s), len(s))
}

/* Terminal */
die :: proc "c" (s: cstring) -> int {
	editor_refresh_screen()
	libc.perror(s)
	libc.exit(1)
}

disable_raw_mode :: proc "c" () {
	res := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &E.orig_termios)
	if res == .FAIL {
		die("tcsetattr")
	}
}

enable_raw_mode :: proc "c" () {
	res := posix.tcgetattr(posix.STDIN_FILENO, &E.orig_termios)
	if res == .FAIL {
		die("tcgetattr")
	}
	posix.atexit(disable_raw_mode)
	raw := E.orig_termios
	raw.c_iflag -= {.BRKINT, .INPCK, .ISTRIP, .IXON, .ICRNL}
	raw.c_oflag -= {.OPOST}
	raw.c_cflag |= {.CS8}
	raw.c_lflag -= {.ECHO, .ICANON, .ISIG, .IEXTEN}
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 1
	res = posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw)
	if res == .FAIL {
		die("tcsetattr")
	}
}

editor_refresh_screen :: proc "c" () {
	posix_write_stdout("\x1b[2J")
}

editor_position_cursor :: proc "c" () {
	posix_write_stdout("\x1b[H")
}

/* Editor */
init_editor :: proc() {
	res := get_window_size(&E.screencols, &E.screenrows)
	if res == -1 {
		die("get_window_size")
	}
}


get_window_size :: proc(cols: ^u16, rows: ^u16) -> int {
	ws: Winsize

	result := ioctl(posix.STDOUT_FILENO, darwin.TIOCGWINSZ, &ws)
	if result == -1 || ws.ws_col == 0 {
		n, err := write_stdout("\x1b[999C\x1b[999B")
		if n != 12 || err != nil {
			return -1
		}
		return get_cursor_position(rows, cols)
	}

	cols^ = ws.ws_col
	rows^ = ws.ws_row

	return 0
}


get_cursor_position :: proc(rows: ^u16, cols: ^u16) -> int {
	write_stdout("\x1b[6n")
	buf: [32]byte
	j: int
	for i := 0; i < len(buf); i += 1 {
		n, err := os.read_ptr(os.stdin, &buf[i], 1)
		if n != 1 {
			break
		}
		if buf[i] == 'R' {
			j = i
			break
		}
	}
	if buf[0] != '\x1b' || buf[1] != '[' {
		return -1
	}
	size_str: cstring = strings.clone_to_cstring(transmute(string)buf[2:j])
	res := libc.sscanf(size_str, "%d;%d", rows, cols)
	if res != 2 {
		return -1
	}
	return 0
}

editor_draw_columns :: proc() {
	tilde := "~"
	nl := "\r\n"
	for i: u16 = 0; i < E.screencols; i += 1 {
		os.write(os.stdin, transmute([]u8)tilde)
		if (i < E.screencols - 1) {
			os.write(os.stdin, transmute([]u8)nl)
		}
	}
}

editor_process_key_presses :: proc() {
	c: byte = editor_read_key()
	if c == ctrl_key('q') {
		editor_refresh_screen()
		libc.exit(libc.EXIT_SUCCESS)
	}
}

editor_read_key :: proc() -> byte {
	c: [1]byte
	for {
		n, err := os.read(os.stdin, c[:])
		if n == -1 {
			die("read")
		}
		if n == 1 {
			return c[0]
		}
	}
}
ctrl_key :: proc(c: byte) -> byte {
	return c & 0x1f
}


main :: proc() {
	enable_raw_mode()
	init_editor()
	for {
		editor_position_cursor()
		editor_refresh_screen()
		editor_draw_columns()
		editor_position_cursor()
		editor_process_key_presses()
	}
	return
}
