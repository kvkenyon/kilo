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


KILO_VERSION :: "0.0.1"


EditorConfig :: struct {
	orig_termios: posix.termios,
	screenrows:   u16,
	screencols:   u16,
	cx:           u16,
	cy:           u16,
}

EditorKey :: enum {
	ARROW_UP = 1000,
	ARROW_DOWN,
	ARROW_LEFT,
	ARROW_RIGHT,
}


@(private = "file")
E: EditorConfig


/* Helpers */
write_stdout :: proc(s: string) -> (n: int, err: os.Error) {
	return os.write(os.stdout, transmute([]u8)s)
}


posix_write_stdout :: proc "c" (s: string) {
	posix.write(posix.STDOUT_FILENO, raw_data(s), len(s))
}


/* Terminal */
die :: proc "c" (s: cstring) -> int {
	posix_write_stdout("\x1b[2J")
	posix_write_stdout("\x1b[H")
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


/* Editor */
init_editor :: proc() {
	E.cx, E.cy = 0, 0
	if res := get_window_size(&E.screencols, &E.screenrows); res == -1 do die("get_window_size")
}


get_window_size :: proc(cols: ^u16, rows: ^u16) -> int {
	ws: Winsize
	result := ioctl(posix.STDOUT_FILENO, darwin.TIOCGWINSZ, &ws)
	if result == -1 || ws.ws_col == 0 {
		n, err := write_stdout("\x1b[999C\x1b[999B")
		if n != 12 || err != nil do return -1
		return get_cursor_position(rows, cols)
	}
	cols^ = ws.ws_col
	rows^ = ws.ws_row
	return 0
}


get_cursor_position :: proc(rows: ^u16, cols: ^u16) -> int {
	write_stdout("\x1b[6n") // Get cursor status.
	buf: [32]byte
	i: int = 0
	for ; i < len(buf); i += 1 {
		n, err := os.read_ptr(os.stdin, &buf[i], 1)
		if n != 1 do break
		if buf[i] == 'R' do break
	}
	if buf[0] != '\x1b' || buf[1] != '[' do return -1
	size_str: cstring = strings.clone_to_cstring(transmute(string)buf[2:i])
	res := libc.sscanf(size_str, "%d;%d", rows, cols)
	if res != 2 do return -1
	return 0
}


editor_draw_rows :: proc(abuf: ^[dynamic]byte) {
	for y: u16 = 0; y < E.screenrows; y += 1 {
		if y == E.screenrows / 3 {
			welcome: [80]byte
			welcome_string := fmt.bprintf(welcome[:], "Kilo editor -- version %s", KILO_VERSION)
			welcome_len := len(welcome_string)
			if welcome_len > auto_cast E.screencols do welcome_len = auto_cast E.screencols
			padding := (E.screencols - auto_cast welcome_len) / 2
			if padding > 0 {
				append(abuf, "~")
				padding -= 1
			}
			for i: u16 = 0; i < padding; i += 1 do append(abuf, " ")
			append(abuf, welcome_string)
		} else {
			append(abuf, "~")
		}
		append(abuf, "\x1b[K") // Clear the line.
		if (y < E.screenrows - 1) do append(abuf, "\r\n")
	}
}


editor_refresh_screen :: proc() {
	abuf: [dynamic]byte
	append(&abuf, "\x1b[?25l")
	append(&abuf, "\x1b[H")
	editor_draw_rows(&abuf)
	// Draw cursor
	buf: [32]byte
	draw_cursor := fmt.bprintf(buf[:], "\x1b[%d;%dH", E.cy + 1, E.cx + 1)
	append(&abuf, draw_cursor)
	append(&abuf, "\x1b[?25h")
	os.write(os.stdout, abuf[:])
}

/* Input */

editor_move_cursor :: proc(key: int) {
	switch key {
	case auto_cast EditorKey.ARROW_DOWN:
		if E.cy != E.screenrows - 1 {
			E.cy += 1
		}
	case auto_cast EditorKey.ARROW_UP:
		if E.cy != 0 {
			E.cy -= 1
		}
	case auto_cast EditorKey.ARROW_LEFT:
		if E.cx != 0 {
			E.cx -= 1
		}
	case auto_cast EditorKey.ARROW_RIGHT:
		if E.cx != E.screencols - 1 {
			E.cx += 1
		}
	}
}

editor_process_key_presses :: proc() {
	c: int = editor_read_key()
	switch c {
	case ctrl_key('q'):
		write_stdout("\x1b[2J")
		write_stdout("\x1b[H")
		libc.exit(libc.EXIT_SUCCESS)
	case auto_cast EditorKey.ARROW_UP:
		fallthrough
	case auto_cast EditorKey.ARROW_DOWN:
		fallthrough
	case auto_cast EditorKey.ARROW_RIGHT:
		fallthrough
	case auto_cast EditorKey.ARROW_LEFT:
		editor_move_cursor(c)
	}
}


editor_read_key :: proc() -> int {
	c: [1]byte
	for {
		n, err := os.read(os.stdin, c[:])
		if n == -1 do die("read")
		if n == 1 do break
	}
	key := c[0]
	if key == '\x1b' {
		buf: [3]byte
		if n, err := os.read_ptr(os.stdin, &buf[0], 1); n != 1 do return '\x1b'
		if n, err := os.read_ptr(os.stdin, &buf[1], 1); n != 1 do return '\x1b'

		if buf[0] == '[' {
			switch buf[1] {
			case 'A':
				return auto_cast EditorKey.ARROW_UP
			case 'B':
				return auto_cast EditorKey.ARROW_DOWN
			case 'C':
				return auto_cast EditorKey.ARROW_RIGHT
			case 'D':
				return auto_cast EditorKey.ARROW_LEFT
			}
		}
		return '\x1b'
	} else {
		return cast(int)key
	}
}


ctrl_key :: proc(c: byte) -> int {
	return cast(int)c & 0x1f
}


main :: proc() {
	enable_raw_mode()
	init_editor()
	for {
		editor_refresh_screen()
		editor_process_key_presses()
	}
	return
}
