#ifndef MT_TERMINAL_SUPPORT_H
#define MT_TERMINAL_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <errno.h>
#include <io.h>
#include <windows.h>
#else
#include <errno.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#endif

typedef struct mt_terminal_size {
  int width;
  int height;
} mt_terminal_size;

typedef struct mt_terminal_error {
  int code;
  char* message_data;
  uintptr_t message_len;
} mt_terminal_error;

static inline void mt_terminal_reset_error(mt_terminal_error* error) {
  if (error == NULL) {
    return;
  }

  error->code = 0;
  error->message_data = NULL;
  error->message_len = 0;
}

static inline int mt_terminal_set_message(mt_terminal_error* error, int code, const char* prefix, const char* detail) {
  if (error == NULL) {
    return code == 0 ? -1 : code;
  }

  size_t prefix_len = prefix == NULL ? 0 : strlen(prefix);
  size_t detail_len = detail == NULL ? 0 : strlen(detail);
  size_t separator_len = prefix_len != 0 && detail_len != 0 ? 2 : 0;
  size_t total_len = prefix_len + separator_len + detail_len;

  char* message = NULL;
  if (total_len != 0) {
    message = (char*) malloc(total_len);
    if (message != NULL) {
      size_t offset = 0;
      if (prefix_len != 0) {
        memcpy(message + offset, prefix, prefix_len);
        offset += prefix_len;
      }
      if (separator_len != 0) {
        memcpy(message + offset, ": ", separator_len);
        offset += separator_len;
      }
      if (detail_len != 0) {
        memcpy(message + offset, detail, detail_len);
      }
    }
  }

  error->code = code;
  error->message_data = message;
  error->message_len = (uintptr_t) total_len;
  return code == 0 ? -1 : code;
}

static inline int mt_terminal_set_errno_error(mt_terminal_error* error, int code, const char* prefix) {
  if (code == 0) {
    code = errno == 0 ? EIO : errno;
  }
  return mt_terminal_set_message(error, code, prefix, strerror(code));
}

#if defined(_WIN32)
static inline int mt_terminal_set_windows_error(mt_terminal_error* error, DWORD code, const char* prefix) {
  char buffer[256];
  DWORD written = FormatMessageA(
      FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
      NULL,
      code,
      0,
      buffer,
      (DWORD) sizeof(buffer),
      NULL);
  if (written == 0) {
    return mt_terminal_set_message(error, (int) code, prefix, "windows terminal error");
  }

  while (written > 0 && (buffer[written - 1] == '\r' || buffer[written - 1] == '\n')) {
    written -= 1;
  }
  buffer[written] = '\0';
  return mt_terminal_set_message(error, (int) code, prefix, buffer);
}
#endif

static inline bool mt_terminal_stdin_is_tty(void) {
#if defined(_WIN32)
  return _isatty(_fileno(stdin)) != 0;
#else
  return isatty(STDIN_FILENO) != 0;
#endif
}

static inline bool mt_terminal_stdout_is_tty(void) {
#if defined(_WIN32)
  return _isatty(_fileno(stdout)) != 0;
#else
  return isatty(STDOUT_FILENO) != 0;
#endif
}

static inline bool mt_terminal_stderr_is_tty(void) {
#if defined(_WIN32)
  return _isatty(_fileno(stderr)) != 0;
#else
  return isatty(STDERR_FILENO) != 0;
#endif
}

#if defined(_WIN32)
static DWORD mt_terminal_saved_input_mode = 0;
static DWORD mt_terminal_saved_output_mode = 0;
static bool mt_terminal_raw_mode_active = false;
#else
static struct termios mt_terminal_saved_mode;
static bool mt_terminal_raw_mode_active = false;
#endif

static inline int mt_terminal_get_size(mt_terminal_size* result, mt_terminal_error* error) {
  mt_terminal_reset_error(error);
  if (result != NULL) {
    result->width = 0;
    result->height = 0;
  }

#if defined(_WIN32)
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (output == INVALID_HANDLE_VALUE) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal size query failed");
  }

  CONSOLE_SCREEN_BUFFER_INFO info;
  if (!GetConsoleScreenBufferInfo(output, &info)) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal size query failed");
  }

  if (result != NULL) {
    result->width = (int) (info.srWindow.Right - info.srWindow.Left + 1);
    result->height = (int) (info.srWindow.Bottom - info.srWindow.Top + 1);
  }
  return 0;
#else
  if (!mt_terminal_stdout_is_tty()) {
    return mt_terminal_set_message(error, ENOTTY, "terminal size query failed", "stdout is not a tty");
  }

  struct winsize window;
  memset(&window, 0, sizeof(window));
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) != 0) {
    return mt_terminal_set_errno_error(error, errno, "terminal size query failed");
  }

  if (result != NULL) {
    result->width = (int) window.ws_col;
    result->height = (int) window.ws_row;
  }
  return 0;
#endif
}

static inline int mt_terminal_enter_raw_mode(mt_terminal_error* error) {
  mt_terminal_reset_error(error);
  if (mt_terminal_raw_mode_active) {
    return 0;
  }

#if defined(_WIN32)
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (input == INVALID_HANDLE_VALUE || output == INVALID_HANDLE_VALUE) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode failed");
  }

  DWORD input_mode = 0;
  DWORD output_mode = 0;
  if (!GetConsoleMode(input, &input_mode)) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode failed");
  }
  if (!GetConsoleMode(output, &output_mode)) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode failed");
  }

  DWORD raw_input_mode = input_mode;
  raw_input_mode &= ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
  raw_input_mode |= ENABLE_VIRTUAL_TERMINAL_INPUT;
  if (!SetConsoleMode(input, raw_input_mode)) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode failed");
  }

  DWORD ansi_output_mode = output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
  if (!SetConsoleMode(output, ansi_output_mode)) {
    SetConsoleMode(input, input_mode);
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode failed");
  }

  mt_terminal_saved_input_mode = input_mode;
  mt_terminal_saved_output_mode = output_mode;
  mt_terminal_raw_mode_active = true;
  return 0;
#else
  if (!mt_terminal_stdin_is_tty()) {
    return mt_terminal_set_message(error, ENOTTY, "terminal raw mode failed", "stdin is not a tty");
  }

  struct termios raw;
  if (tcgetattr(STDIN_FILENO, &mt_terminal_saved_mode) != 0) {
    return mt_terminal_set_errno_error(error, errno, "terminal raw mode failed");
  }

  raw = mt_terminal_saved_mode;
  raw.c_iflag &= (tcflag_t) ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
  raw.c_oflag &= (tcflag_t) ~(OPOST);
  raw.c_cflag |= (tcflag_t) CS8;
  raw.c_lflag &= (tcflag_t) ~(ECHO | ICANON | IEXTEN | ISIG);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;

  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) {
    return mt_terminal_set_errno_error(error, errno, "terminal raw mode failed");
  }

  mt_terminal_raw_mode_active = true;
  return 0;
#endif
}

static inline int mt_terminal_leave_raw_mode(mt_terminal_error* error) {
  mt_terminal_reset_error(error);
  if (!mt_terminal_raw_mode_active) {
    return 0;
  }

#if defined(_WIN32)
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  if (input == INVALID_HANDLE_VALUE || output == INVALID_HANDLE_VALUE) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode restore failed");
  }

  if (!SetConsoleMode(input, mt_terminal_saved_input_mode)) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode restore failed");
  }
  if (!SetConsoleMode(output, mt_terminal_saved_output_mode)) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal raw mode restore failed");
  }

  mt_terminal_raw_mode_active = false;
  return 0;
#else
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &mt_terminal_saved_mode) != 0) {
    return mt_terminal_set_errno_error(error, errno, "terminal raw mode restore failed");
  }

  mt_terminal_raw_mode_active = false;
  return 0;
#endif
}

static inline int mt_terminal_write_stream(FILE* stream, const unsigned char* data, uintptr_t len, uintptr_t* out_written, mt_terminal_error* error) {
  mt_terminal_reset_error(error);
  if (out_written != NULL) {
    *out_written = 0;
  }

  if (len == 0) {
    return 0;
  }
  if (stream == NULL || data == NULL) {
    return mt_terminal_set_message(error, EINVAL, "terminal write failed", "missing output buffer");
  }

  if ((uintptr_t) ((size_t) len) != len) {
    return mt_terminal_set_message(error, EOVERFLOW, "terminal write failed", "buffer too large");
  }

  size_t written = fwrite(data, 1, (size_t) len, stream);
  if (out_written != NULL) {
    *out_written = (uintptr_t) written;
  }
  if (written != (size_t) len) {
    int code = errno == 0 ? EIO : errno;
    return mt_terminal_set_errno_error(error, code, "terminal write failed");
  }

  return 0;
}

static inline int mt_terminal_write_stdout(const unsigned char* data, uintptr_t len, uintptr_t* out_written, mt_terminal_error* error) {
  return mt_terminal_write_stream(stdout, data, len, out_written, error);
}

static inline int mt_terminal_write_stderr(const unsigned char* data, uintptr_t len, uintptr_t* out_written, mt_terminal_error* error) {
  return mt_terminal_write_stream(stderr, data, len, out_written, error);
}

static inline int mt_terminal_flush_stdout(mt_terminal_error* error) {
  mt_terminal_reset_error(error);
  if (fflush(stdout) != 0) {
    return mt_terminal_set_errno_error(error, errno, "terminal flush failed");
  }
  return 0;
}

static inline int mt_terminal_flush_stderr(mt_terminal_error* error) {
  mt_terminal_reset_error(error);
  if (fflush(stderr) != 0) {
    return mt_terminal_set_errno_error(error, errno, "terminal flush failed");
  }
  return 0;
}

static inline int mt_terminal_read_stdin(unsigned char* buffer, uintptr_t capacity, int timeout_ms, uintptr_t* out_read, mt_terminal_error* error) {
  mt_terminal_reset_error(error);
  if (out_read != NULL) {
    *out_read = 0;
  }

  if (capacity == 0) {
    return 0;
  }
  if (buffer == NULL) {
    return mt_terminal_set_message(error, EINVAL, "terminal read failed", "missing input buffer");
  }

#if defined(_WIN32)
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  if (input == INVALID_HANDLE_VALUE) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal read failed");
  }

  DWORD wait_ms = timeout_ms < 0 ? INFINITE : (DWORD) timeout_ms;
  DWORD wait_result = WaitForSingleObject(input, wait_ms);
  if (wait_result == WAIT_TIMEOUT) {
    return 0;
  }
  if (wait_result != WAIT_OBJECT_0) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal read failed");
  }

  DWORD requested = capacity > (uintptr_t) UINT32_MAX ? UINT32_MAX : (DWORD) capacity;
  DWORD read_count = 0;
  if (!ReadFile(input, buffer, requested, &read_count, NULL)) {
    return mt_terminal_set_windows_error(error, GetLastError(), "terminal read failed");
  }

  if (out_read != NULL) {
    *out_read = (uintptr_t) read_count;
  }
  return 0;
#else
  if (timeout_ms >= 0) {
    struct pollfd descriptor;
    descriptor.fd = STDIN_FILENO;
    descriptor.events = POLLIN;
    descriptor.revents = 0;

    int poll_status;
    do {
      poll_status = poll(&descriptor, 1, timeout_ms);
    } while (poll_status < 0 && errno == EINTR);

    if (poll_status == 0) {
      return 0;
    }
    if (poll_status < 0) {
      return mt_terminal_set_errno_error(error, errno, "terminal read failed");
    }
  }

  ssize_t read_count;
  do {
    read_count = read(STDIN_FILENO, buffer, (size_t) capacity);
  } while (read_count < 0 && errno == EINTR);

  if (read_count < 0) {
    return mt_terminal_set_errno_error(error, errno, "terminal read failed");
  }

  if (out_read != NULL) {
    *out_read = (uintptr_t) read_count;
  }
  return 0;
#endif
}

#endif