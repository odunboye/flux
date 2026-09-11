/*
 * iristui.c — low-level terminal I/O helper for the Iris TUI backend.
 *
 * Provides: raw mode, terminal size, non-blocking stdin read, stdout write,
 * and a millisecond sleep.  Supports macOS / Linux (POSIX) and Windows.
 */

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#  include <conio.h>
#else
#  include <termios.h>
#  include <unistd.h>
#  include <sys/ioctl.h>
#  include <fcntl.h>
#  include <errno.h>
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Terminal state ────────────────────────────────────────────────────────── */

#ifndef _WIN32
static struct termios orig_termios;
static int raw_mode_active = 0;
#endif

/* ── Raw mode ──────────────────────────────────────────────────────────────── */

void iris_tui_raw_on(void) {
#ifndef _WIN32
    if (raw_mode_active) return;
    if (tcgetattr(STDIN_FILENO, &orig_termios) < 0) return;
    struct termios raw = orig_termios;
    /* disable canonical mode, echo, signals, extended processing */
    raw.c_lflag &= ~(unsigned)(ECHO | ICANON | ISIG | IEXTEN);
    /* disable flow control, CR→NL mapping, parity */
    raw.c_iflag &= ~(unsigned)(IXON | ICRNL | BRKINT | INPCK | ISTRIP);
    raw.c_cflag |= (unsigned)CS8;
    /* disable output processing */
    raw.c_oflag &= ~(unsigned)OPOST;
    /* non-blocking: return immediately if no bytes, 100ms timeout */
    raw.c_cc[VMIN]  = 0;
    raw.c_cc[VTIME] = 1;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    raw_mode_active = 1;
#else
    /* Windows: hide cursor & switch to raw console input */
    HANDLE hin = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    GetConsoleMode(hin, &mode);
    SetConsoleMode(hin, mode & ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT));
#endif
}

void iris_tui_raw_off(void) {
#ifndef _WIN32
    if (!raw_mode_active) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
    raw_mode_active = 0;
#else
    HANDLE hin = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    GetConsoleMode(hin, &mode);
    SetConsoleMode(hin, mode | ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT);
#endif
}

/* ── Terminal size ─────────────────────────────────────────────────────────── */

int iris_tui_cols(void) {
#ifndef _WIN32
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
        return ws.ws_col;
    return 80;
#else
    CONSOLE_SCREEN_BUFFER_INFO csbi;
    if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &csbi))
        return csbi.srWindow.Right - csbi.srWindow.Left + 1;
    return 80;
#endif
}

int iris_tui_rows(void) {
#ifndef _WIN32
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0)
        return ws.ws_row;
    return 24;
#else
    CONSOLE_SCREEN_BUFFER_INFO csbi;
    if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &csbi))
        return csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
    return 24;
#endif
}

/* ── Stdin read ────────────────────────────────────────────────────────────── */

/*
 * Read up to 31 bytes from stdin into a static NUL-terminated buffer.
 * Returns the buffer pointer (empty string "" if nothing was available).
 * The caller must use the string before the next call.
 */
static char read_buf[32];

const char *iris_tui_read(void) {
#ifndef _WIN32
    int n = (int)read(STDIN_FILENO, read_buf, 31);
    if (n <= 0) { read_buf[0] = '\0'; return read_buf; }
    read_buf[n] = '\0';
    return read_buf;
#else
    if (!_kbhit()) { read_buf[0] = '\0'; return read_buf; }
    int c = _getch();
    if (c == 0 || c == 0xe0) {   /* extended / function key */
        read_buf[0] = '\x1b';
        read_buf[1] = '[';
        read_buf[2] = (char)_getch();
        read_buf[3] = '\0';
        return read_buf;
    }
    read_buf[0] = (char)c;
    read_buf[1] = '\0';
    return read_buf;
#endif
}

/* ── Stdout write ──────────────────────────────────────────────────────────── */

void iris_tui_write(const char *s) {
    fputs(s, stdout);
    fflush(stdout);
}

/* ── Sleep ─────────────────────────────────────────────────────────────────── */

void iris_tui_sleep_ms(int ms) {
#ifndef _WIN32
    if (ms > 0) usleep((unsigned int)(ms * 1000));
#else
    if (ms > 0) Sleep((DWORD)ms);
#endif
}
