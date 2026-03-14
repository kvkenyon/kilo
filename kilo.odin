package main

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:sys/posix"

@(private = "file")
orig_termios: posix.termios

die :: proc "c" (s: cstring) -> int {
	libc.perror(s)
	libc.exit(1)
}

_disable_raw_mode :: proc "c" () {
	res := posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &orig_termios)
	if res == .FAIL {
		die("tcsetattr")
	}
}

_enable_raw_mode :: proc() {
	res := posix.tcgetattr(posix.STDIN_FILENO, &orig_termios)
	if res == .FAIL {
		die("tcgetattr")
	}
	posix.atexit(_disable_raw_mode)
	raw := orig_termios
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

main :: proc() {
	_enable_raw_mode()
	c: [1]byte
	for {
		c[0] = '0'
		n, err := os.read(os.stdin, c[:])
		if n == -1 {
			die("read")
		}
		if libc.iscntrl(cast(i32)c[0]) == 1 {
			fmt.printf("%d\r\n", c)
		} else {
			fmt.printf("%d ('%c')\r\n", c, c)
		}
		if c == 'q' {
			break
		}
	}
	return
}
