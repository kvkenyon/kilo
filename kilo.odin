package main
import "core:c/libc"
import "core:fmt"
import "core:log"
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

ERow :: struct {
	size:  int,
	chars: [dynamic]byte,
}

EditorConfig :: struct {
	orig_termios: posix.termios,
	screenrows:   uint,
	screencols:   uint,
	cx:           uint,
	cy:           uint,
	rows:         [dynamic]ERow,
	numrows:      uint,
	coloffset:    uint,
	rowoffset:    uint,
}

EditorKey :: enum {
	ARROW_UP = 1000,
	ARROW_DOWN,
	ARROW_LEFT,
	ARROW_RIGHT,
	PAGE_UP,
	PAGE_DOWN,
	HOME_KEY,
	END_KEY,
	DELETE_KEY,
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

/* File I/O */

editor_open :: proc(filepath: string) {
	data, ok := os.read_entire_file(filepath, context.allocator)
	if ok != nil do die("read_entire_file")
	defer delete(data, context.allocator)
	it := string(data)
	for line in strings.split_lines_iterator(&it) do editor_append_row(line)
}


editor_append_row :: proc(line: string) {
	erow := ERow{}
	append(&erow.chars, line)
	erow.size = len(line)
	append(&E.rows, erow)
	E.numrows += 1
}

/* Editor */

init_editor :: proc() {
	log.info("init_editor")
	E.cx, E.cy, E.numrows, E.rowoffset, E.coloffset = 0, 0, 0, 0, 0
	if res := get_window_size(&E.screencols, &E.screenrows); res == -1 do die("get_window_size")
	log.infof("window_size = (%d, %d)", E.screenrows, E.screencols)
}


get_window_size :: proc(cols: ^uint, rows: ^uint) -> int {
	ws: Winsize
	result := ioctl(posix.STDOUT_FILENO, darwin.TIOCGWINSZ, &ws)
	if result == -1 || ws.ws_col == 0 {
		log.warnf("failed to get windowsize from ioctl")
		n, err := write_stdout("\x1b[999C\x1b[999B")
		if n != 12 || err != nil do return -1
		return get_cursor_position(rows, cols)
	}
	cols^ = cast(uint)ws.ws_col
	rows^ = cast(uint)ws.ws_row
	return 0
}


get_cursor_position :: proc(rows: ^uint, cols: ^uint) -> int {
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
	log.infof("cursor_position = (%d, %d)", rows, cols)
	if res != 2 do return -1
	return 0
}


editor_draw_rows :: proc(abuf: ^[dynamic]byte) {
	for y: uint = 0; y < E.screenrows; y += 1 {
		filerow := y + E.rowoffset
		if y >= E.numrows {
			if y == E.screenrows / 3 && E.numrows == 0 {
				welcome: [80]byte
				welcome_string := fmt.bprintf(
					welcome[:],
					"Kilo editor -- version %s",
					KILO_VERSION,
				)
				welcome_len := len(welcome_string)
				if welcome_len > auto_cast E.screencols do welcome_len = auto_cast E.screencols
				padding: uint = (E.screencols - auto_cast welcome_len) / 2
				if padding > 0 {
					append(abuf, "~")
					padding -= 1
				}
				for i: uint = 0; i < padding; i += 1 do append(abuf, " ")
				append(abuf, welcome_string)
			} else {
				append(abuf, "~")
			}
		} else {
			erow := E.rows[filerow]
			len := erow.size - cast(int)E.coloffset
			if len < 0 do len = 0
			if len > cast(int)E.screencols do len = cast(int)E.screencols
			for i in E.coloffset ..< E.coloffset + cast(uint)len {
				append(abuf, erow.chars[i])
			}
		}
		append(abuf, "\x1b[K") // Clear the line.
		if (y < E.screenrows - 1) do append(abuf, "\r\n")
	}
}

editor_scroll :: proc() {
	log.infof(
		"before scroll: E.cy=%d E.rowoffset=%d E.cx=%d E.coloffset=%d",
		E.cy,
		E.rowoffset,
		E.cx,
		E.coloffset,
	)
	if E.cx < E.coloffset do E.coloffset = E.cx
	if E.cx > E.coloffset + E.screencols - 1 {
		E.coloffset = E.cx - E.screencols + 1
	}
	if E.cy < E.rowoffset do E.rowoffset = E.cy
	if E.cy > E.rowoffset + E.screenrows - 1 {
		E.rowoffset = E.cy - E.screenrows + 1
	}
	log.infof(
		"after scroll: E.cy=%d E.rowoffset=%d E.cx=%d E.coloffset=%d",
		E.cy,
		E.rowoffset,
		E.cx,
		E.coloffset,
	)
}


editor_refresh_screen :: proc() {
	editor_scroll()
	abuf: [dynamic]byte
	append(&abuf, "\x1b[?25l")
	append(&abuf, "\x1b[H")
	editor_draw_rows(&abuf)
	// Draw cursor
	buf: [32]byte
	draw_cursor := fmt.bprintf(
		buf[:],
		"\x1b[%d;%dH",
		(E.cy - E.rowoffset) + 1,
		(E.cx - E.coloffset) + 1,
	)
	append(&abuf, draw_cursor)
	append(&abuf, "\x1b[?25h")
	os.write(os.stdout, abuf[:])
}


/* Input */

editor_move_cursor :: proc(key: int) {
	switch key {
	case auto_cast EditorKey.ARROW_DOWN:
		if E.cy < E.numrows {
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
		E.cx += 1
	}
}

editor_process_key_presses :: proc() {
	c: int = editor_read_key()
	switch c {
	case ctrl_key('q'):
		write_stdout("\x1b[2J")
		write_stdout("\x1b[H")
		libc.exit(libc.EXIT_SUCCESS)
	case auto_cast EditorKey.HOME_KEY:
		E.cx = 0
	case auto_cast EditorKey.END_KEY:
		E.cx = E.screencols - 1
	case auto_cast EditorKey.PAGE_UP:
		fallthrough
	case auto_cast EditorKey.PAGE_DOWN:
		times: uint = E.screenrows - 1
		for i: uint = 0; i < times; i += 1 {
			editor_move_cursor(
				c == auto_cast EditorKey.PAGE_UP ? auto_cast EditorKey.ARROW_UP : auto_cast EditorKey.ARROW_DOWN,
			)
		}
	case auto_cast EditorKey.ARROW_UP:
		fallthrough
	case auto_cast EditorKey.ARROW_DOWN:
		fallthrough
	case auto_cast EditorKey.ARROW_RIGHT:
		fallthrough
	case auto_cast EditorKey.ARROW_LEFT:
		editor_move_cursor(c)
	case auto_cast EditorKey.DELETE_KEY:
		fallthrough
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
		seq: [3]byte
		if n, err := os.read_ptr(os.stdin, &seq[0], 1); n != 1 do return '\x1b'
		if n, err := os.read_ptr(os.stdin, &seq[1], 1); n != 1 do return '\x1b'

		if seq[0] == '[' {
			if seq[1] >= '0' && seq[1] <= '9' {
				if n, err := os.read_ptr(os.stdin, &seq[2], 1); n != 1 do return '\x1b'
				if seq[2] == '~' {
					switch seq[1] {
					case '1':
						return auto_cast EditorKey.HOME_KEY
					case '3':
						return auto_cast EditorKey.DELETE_KEY
					case '4':
						return auto_cast EditorKey.END_KEY
					case '5':
						return auto_cast EditorKey.PAGE_UP
					case '6':
						return auto_cast EditorKey.PAGE_DOWN
					case '7':
						return auto_cast EditorKey.HOME_KEY
					case '8':
						return auto_cast EditorKey.END_KEY
					}
				}
			} else {
				switch seq[1] {
				case 'A':
					return auto_cast EditorKey.ARROW_UP
				case 'B':
					return auto_cast EditorKey.ARROW_DOWN
				case 'C':
					return auto_cast EditorKey.ARROW_RIGHT
				case 'D':
					return auto_cast EditorKey.ARROW_LEFT
				case 'H':
					return auto_cast EditorKey.HOME_KEY
				case 'F':
					return auto_cast EditorKey.END_KEY
				}
			}
		} else if (seq[0] == 'O') {
			switch seq[1] {
			case 'H':
				return auto_cast EditorKey.HOME_KEY
			case 'F':
				return auto_cast EditorKey.END_KEY
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
	logh, logh_err := os.open("log.txt", (os.O_CREATE | os.O_TRUNC | os.O_RDWR))
	logger :=
		logh_err == os.ERROR_NONE ? log.create_file_logger(logh) : log.create_console_logger()
	context.logger = logger

	enable_raw_mode()
	init_editor()
	if len(os.args) >= 2 {
		editor_open(os.args[1])
	}
	for {
		editor_refresh_screen()
		editor_process_key_presses()
	}

	if logh_err == os.ERROR_NONE {
		log.destroy_file_logger(logger)
		os.close(logh)
	}
}
