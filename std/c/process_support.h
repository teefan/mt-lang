#ifndef MT_PROCESS_SUPPORT_H
#define MT_PROCESS_SUPPORT_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdbool.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if !defined(_WIN32)
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#endif

#include <uv.h>

typedef struct mt_process_capture_result {
  char* stdout_data;
  uintptr_t stdout_len;
  char* stderr_data;
  uintptr_t stderr_len;
  int64_t exit_status;
  int term_signal;
} mt_process_capture_result;

typedef struct mt_process_error {
  int code;
  char* message_data;
  uintptr_t message_len;
} mt_process_error;

typedef struct mt_process_spawn_handle {
  int pid;
  int stdin_fd;
  int stdout_fd;
  int stderr_fd;
} mt_process_spawn_handle;

typedef struct mt_process_pty_handle {
  int pid;
  int master_fd;
} mt_process_pty_handle;

typedef struct mt_process_read_result {
  bool ready;
  bool closed;
  char* data;
  uintptr_t len;
} mt_process_read_result;

typedef struct mt_process_wait_result {
  bool ready;
  int64_t exit_status;
  int term_signal;
} mt_process_wait_result;

typedef struct mt_process_buffer {
  char* data;
  uintptr_t len;
  uintptr_t capacity;
} mt_process_buffer;

typedef enum mt_process_failure_stage {
  MT_PROCESS_FAILURE_NONE = 0,
  MT_PROCESS_FAILURE_LOOP_INIT = 1,
  MT_PROCESS_FAILURE_PIPE_INIT = 2,
  MT_PROCESS_FAILURE_SPAWN = 3,
  MT_PROCESS_FAILURE_READ = 4,
  MT_PROCESS_FAILURE_LOOP_CLOSE = 5,
  MT_PROCESS_FAILURE_INTERNAL = 6,
} mt_process_failure_stage;

struct mt_process_capture_state;

typedef struct mt_process_pipe_state {
  struct mt_process_capture_state* capture;
  mt_process_buffer* buffer;
  uv_pipe_t* handle;
  bool close_requested;
} mt_process_pipe_state;

typedef struct mt_process_capture_state {
  uv_loop_t* loop;
  uv_process_t* process;
  uv_pipe_t* stdout_pipe;
  uv_pipe_t* stderr_pipe;
  mt_process_pipe_state stdout_state;
  mt_process_pipe_state stderr_state;
  mt_process_buffer stdout_buffer;
  mt_process_buffer stderr_buffer;
  int pending_closes;
  int failure_code;
  mt_process_failure_stage failure_stage;
  int64_t exit_status;
  int term_signal;
  bool exited;
} mt_process_capture_state;

static inline void mt_process_reset_capture_result(mt_process_capture_result* result) {
  if (result == NULL) {
    return;
  }

  result->stdout_data = NULL;
  result->stdout_len = 0;
  result->stderr_data = NULL;
  result->stderr_len = 0;
  result->exit_status = 0;
  result->term_signal = 0;
}

static inline void mt_process_reset_error(mt_process_error* error) {
  if (error == NULL) {
    return;
  }

  error->code = 0;
  error->message_data = NULL;
  error->message_len = 0;
}

static inline void mt_process_buffer_release(mt_process_buffer* buffer) {
  if (buffer == NULL) {
    return;
  }

  free(buffer->data);
  buffer->data = NULL;
  buffer->len = 0;
  buffer->capacity = 0;
}

static inline bool mt_process_buffer_append(mt_process_buffer* buffer, const char* data, uintptr_t len) {
  if (len == 0) {
    return true;
  }
  if (buffer == NULL || data == NULL) {
    return false;
  }
  if (buffer->len > UINTPTR_MAX - len) {
    return false;
  }

  uintptr_t required = buffer->len + len;
  if (required > buffer->capacity) {
    uintptr_t new_capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
    while (new_capacity < required) {
      if (new_capacity > UINTPTR_MAX / 2) {
        new_capacity = required;
        break;
      }
      new_capacity *= 2;
    }

    char* resized = (char*) realloc(buffer->data, (size_t) new_capacity);
    if (resized == NULL) {
      return false;
    }

    buffer->data = resized;
    buffer->capacity = new_capacity;
  }

  memcpy(buffer->data + buffer->len, data, (size_t) len);
  buffer->len = required;
  return true;
}

static inline void mt_process_note_failure(mt_process_capture_state* state, int code, mt_process_failure_stage stage) {
  if (state == NULL || state->failure_code != 0) {
    return;
  }

  state->failure_code = code;
  state->failure_stage = stage;
}

static inline int mt_process_set_message(mt_process_error* error, int code, const char* prefix, const char* detail) {
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

static inline int mt_process_set_uv_error(mt_process_error* error, int code, const char* prefix) {
  return mt_process_set_message(error, code, prefix, uv_strerror(code));
}

static void mt_process_capture_pipe_close_cb(uv_handle_t* handle);
static void mt_process_capture_process_close_cb(uv_handle_t* handle);

static inline void mt_process_capture_begin_close_pipe(mt_process_pipe_state* pipe_state) {
  if (pipe_state == NULL || pipe_state->handle == NULL || pipe_state->close_requested) {
    return;
  }

  pipe_state->close_requested = true;
  uv_read_stop((uv_stream_t*) pipe_state->handle);
  uv_close((uv_handle_t*) pipe_state->handle, mt_process_capture_pipe_close_cb);
}

static void mt_process_capture_alloc_cb(uv_handle_t* handle, size_t suggested_size, uv_buf_t* buf) {
  (void) handle;

  size_t buffer_size = suggested_size == 0 ? 1 : suggested_size;
  char* memory = (char*) malloc(buffer_size);
  if (memory == NULL) {
    *buf = uv_buf_init(NULL, 0);
    return;
  }

  *buf = uv_buf_init(memory, (unsigned int) buffer_size);
}

static void mt_process_capture_pipe_close_cb(uv_handle_t* handle) {
  mt_process_pipe_state* pipe_state = (mt_process_pipe_state*) handle->data;
  if (pipe_state != NULL && pipe_state->capture != NULL) {
    if (pipe_state->capture->pending_closes > 0) {
      pipe_state->capture->pending_closes -= 1;
    }
    pipe_state->handle = NULL;
  }

  free(handle);
}

static void mt_process_capture_process_close_cb(uv_handle_t* handle) {
  mt_process_capture_state* state = (mt_process_capture_state*) handle->data;
  if (state != NULL) {
    if (state->pending_closes > 0) {
      state->pending_closes -= 1;
    }
    state->process = NULL;
  }

  free(handle);
}

static void mt_process_capture_read_cb(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf) {
  mt_process_pipe_state* pipe_state = (mt_process_pipe_state*) stream->data;
  if (pipe_state == NULL || pipe_state->capture == NULL) {
    if (buf != NULL && buf->base != NULL) {
      free(buf->base);
    }
    return;
  }

  if (nread > 0) {
    if (!mt_process_buffer_append(pipe_state->buffer, buf->base, (uintptr_t) nread)) {
      mt_process_note_failure(pipe_state->capture, UV_ENOMEM, MT_PROCESS_FAILURE_READ);
      mt_process_capture_begin_close_pipe(pipe_state);
    }
  } else if (nread < 0) {
    if (nread != UV_EOF) {
      mt_process_note_failure(pipe_state->capture, (int) nread, MT_PROCESS_FAILURE_READ);
    }
    mt_process_capture_begin_close_pipe(pipe_state);
  }

  if (buf != NULL && buf->base != NULL) {
    free(buf->base);
  }
}

static void mt_process_capture_exit_cb(uv_process_t* process, int64_t exit_status, int term_signal) {
  mt_process_capture_state* state = (mt_process_capture_state*) process->data;
  if (state == NULL) {
    return;
  }

  state->exit_status = exit_status;
  state->term_signal = term_signal;
  state->exited = true;
  uv_close((uv_handle_t*) process, mt_process_capture_process_close_cb);
}

static inline void mt_process_capture_cleanup_before_spawn_failure(mt_process_capture_state* state) {
  if (state == NULL || state->loop == NULL) {
    return;
  }

  mt_process_capture_begin_close_pipe(&state->stdout_state);
  mt_process_capture_begin_close_pipe(&state->stderr_state);

  if (state->pending_closes > 0) {
    uv_run(state->loop, UV_RUN_DEFAULT);
  }

  if (state->process != NULL) {
    free(state->process);
    state->process = NULL;
  }
}

static inline int mt_process_capture_finish(mt_process_capture_state* state, mt_process_capture_result* out_result, mt_process_error* out_error) {
  int close_status = uv_loop_close(state->loop);
  free(state->loop);
  state->loop = NULL;

  if (close_status != 0) {
    mt_process_buffer_release(&state->stdout_buffer);
    mt_process_buffer_release(&state->stderr_buffer);
    return mt_process_set_uv_error(out_error, close_status, "process loop close failed");
  }

  if (!state->exited) {
    mt_process_buffer_release(&state->stdout_buffer);
    mt_process_buffer_release(&state->stderr_buffer);
    return mt_process_set_message(out_error, -1, "process exited early", NULL);
  }

  if (state->failure_code != 0) {
    const char* prefix = "process read failed";
    if (state->failure_stage == MT_PROCESS_FAILURE_INTERNAL) {
      prefix = "process failed";
    }
    mt_process_buffer_release(&state->stdout_buffer);
    mt_process_buffer_release(&state->stderr_buffer);
    return mt_process_set_uv_error(out_error, state->failure_code, prefix);
  }

  out_result->stdout_data = state->stdout_buffer.data;
  out_result->stdout_len = state->stdout_buffer.len;
  out_result->stderr_data = state->stderr_buffer.data;
  out_result->stderr_len = state->stderr_buffer.len;
  out_result->exit_status = state->exit_status;
  out_result->term_signal = state->term_signal;

  state->stdout_buffer.data = NULL;
  state->stdout_buffer.len = 0;
  state->stdout_buffer.capacity = 0;
  state->stderr_buffer.data = NULL;
  state->stderr_buffer.len = 0;
  state->stderr_buffer.capacity = 0;
  return 0;
}

static inline int mt_process_capture(const char* file, char** args, char** env, const char* cwd, mt_process_capture_result* out_result, mt_process_error* out_error) {
  mt_process_capture_state state;
  memset(&state, 0, sizeof(state));
  mt_process_reset_capture_result(out_result);
  mt_process_reset_error(out_error);

  if (file == NULL || args == NULL || args[0] == NULL) {
    return mt_process_set_message(out_error, -1, "process command cannot be empty", NULL);
  }

  state.loop = (uv_loop_t*) calloc(1, uv_loop_size());
  if (state.loop == NULL) {
    return mt_process_set_message(out_error, UV_ENOMEM, "process loop allocation failed", uv_strerror(UV_ENOMEM));
  }

  int loop_status = uv_loop_init(state.loop);
  if (loop_status != 0) {
    free(state.loop);
    state.loop = NULL;
    return mt_process_set_uv_error(out_error, loop_status, "process loop init failed");
  }

  state.stdout_pipe = (uv_pipe_t*) calloc(1, uv_handle_size(UV_NAMED_PIPE));
  state.stderr_pipe = (uv_pipe_t*) calloc(1, uv_handle_size(UV_NAMED_PIPE));
  state.process = (uv_process_t*) calloc(1, uv_handle_size(UV_PROCESS));
  if (state.stdout_pipe == NULL || state.stderr_pipe == NULL || state.process == NULL) {
    mt_process_buffer_release(&state.stdout_buffer);
    mt_process_buffer_release(&state.stderr_buffer);
    mt_process_capture_cleanup_before_spawn_failure(&state);
    return mt_process_set_message(out_error, UV_ENOMEM, "process handle allocation failed", uv_strerror(UV_ENOMEM));
  }

  state.stdout_state.capture = &state;
  state.stdout_state.buffer = &state.stdout_buffer;
  state.stdout_state.handle = state.stdout_pipe;
  state.stderr_state.capture = &state;
  state.stderr_state.buffer = &state.stderr_buffer;
  state.stderr_state.handle = state.stderr_pipe;

  int stdout_init = uv_pipe_init(state.loop, state.stdout_pipe, 0);
  if (stdout_init != 0) {
    mt_process_capture_cleanup_before_spawn_failure(&state);
    return mt_process_set_uv_error(out_error, stdout_init, "process stdout pipe init failed");
  }
  state.pending_closes += 1;
  state.stdout_pipe->data = &state.stdout_state;

  int stderr_init = uv_pipe_init(state.loop, state.stderr_pipe, 0);
  if (stderr_init != 0) {
    mt_process_capture_cleanup_before_spawn_failure(&state);
    return mt_process_set_uv_error(out_error, stderr_init, "process stderr pipe init failed");
  }
  state.pending_closes += 1;
  state.stderr_pipe->data = &state.stderr_state;

  uv_stdio_container_t stdio[3];
  memset(stdio, 0, sizeof(stdio));
  stdio[0].flags = UV_IGNORE;
  stdio[1].flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE;
  stdio[1].data.stream = (uv_stream_t*) state.stdout_pipe;
  stdio[2].flags = UV_CREATE_PIPE | UV_WRITABLE_PIPE;
  stdio[2].data.stream = (uv_stream_t*) state.stderr_pipe;

  uv_process_options_t options;
  memset(&options, 0, sizeof(options));
  options.exit_cb = mt_process_capture_exit_cb;
  options.file = file;
  options.args = args;
  options.env = env;
  options.cwd = cwd;
  options.stdio_count = 3;
  options.stdio = stdio;

  state.process->data = &state;
  int spawn_status = uv_spawn(state.loop, state.process, &options);
  if (spawn_status != 0) {
    mt_process_capture_cleanup_before_spawn_failure(&state);
    return mt_process_set_uv_error(out_error, spawn_status, "process spawn failed");
  }
  state.pending_closes += 1;

  int stdout_read_status = uv_read_start((uv_stream_t*) state.stdout_pipe, mt_process_capture_alloc_cb, mt_process_capture_read_cb);
  if (stdout_read_status != 0) {
    mt_process_note_failure(&state, stdout_read_status, MT_PROCESS_FAILURE_READ);
    mt_process_capture_begin_close_pipe(&state.stdout_state);
  }

  int stderr_read_status = uv_read_start((uv_stream_t*) state.stderr_pipe, mt_process_capture_alloc_cb, mt_process_capture_read_cb);
  if (stderr_read_status != 0) {
    mt_process_note_failure(&state, stderr_read_status, MT_PROCESS_FAILURE_READ);
    mt_process_capture_begin_close_pipe(&state.stderr_state);
  }

  uv_run(state.loop, UV_RUN_DEFAULT);
  return mt_process_capture_finish(&state, out_result, out_error);
}

static void mt_process_detached_close_cb(uv_handle_t* handle) {
  free(handle);
}

static inline int mt_process_spawn_detached(const char* file, char** args, char** env, const char* cwd, int* out_pid, mt_process_error* out_error) {
  mt_process_reset_error(out_error);
  if (out_pid != NULL) {
    *out_pid = 0;
  }

  if (file == NULL || args == NULL || args[0] == NULL) {
    return mt_process_set_message(out_error, -1, "process command cannot be empty", NULL);
  }

  uv_loop_t* loop = (uv_loop_t*) calloc(1, uv_loop_size());
  if (loop == NULL) {
    return mt_process_set_message(out_error, UV_ENOMEM, "process loop allocation failed", uv_strerror(UV_ENOMEM));
  }

  int loop_status = uv_loop_init(loop);
  if (loop_status != 0) {
    free(loop);
    return mt_process_set_uv_error(out_error, loop_status, "process loop init failed");
  }

  uv_process_t* process = (uv_process_t*) calloc(1, uv_handle_size(UV_PROCESS));
  if (process == NULL) {
    int close_status = uv_loop_close(loop);
    free(loop);
    if (close_status != 0) {
      return mt_process_set_uv_error(out_error, close_status, "process loop close failed");
    }
    return mt_process_set_message(out_error, UV_ENOMEM, "process handle allocation failed", uv_strerror(UV_ENOMEM));
  }

  uv_stdio_container_t stdio[3];
  memset(stdio, 0, sizeof(stdio));
  stdio[0].flags = UV_IGNORE;
  stdio[1].flags = UV_IGNORE;
  stdio[2].flags = UV_IGNORE;

  uv_process_options_t options;
  memset(&options, 0, sizeof(options));
  options.file = file;
  options.args = args;
  options.env = env;
  options.cwd = cwd;
  options.flags = UV_PROCESS_DETACHED;
  options.stdio_count = 3;
  options.stdio = stdio;

  int spawn_status = uv_spawn(loop, process, &options);
  if (spawn_status != 0) {
    free(process);
    int close_status = uv_loop_close(loop);
    free(loop);
    if (close_status != 0) {
      return mt_process_set_uv_error(out_error, close_status, "process loop close failed");
    }
    return mt_process_set_uv_error(out_error, spawn_status, "process spawn failed");
  }

  if (out_pid != NULL) {
    *out_pid = (int) uv_process_get_pid(process);
  }

  uv_unref((uv_handle_t*) process);
  uv_close((uv_handle_t*) process, mt_process_detached_close_cb);
  uv_run(loop, UV_RUN_DEFAULT);

  int close_status = uv_loop_close(loop);
  free(loop);
  if (close_status != 0) {
    return mt_process_set_uv_error(out_error, close_status, "process loop close failed");
  }

  return 0;
}

static inline void mt_process_reset_spawn_handle(mt_process_spawn_handle* handle) {
  if (handle == NULL) {
    return;
  }

  handle->pid = 0;
  handle->stdin_fd = -1;
  handle->stdout_fd = -1;
  handle->stderr_fd = -1;
}

static inline void mt_process_reset_pty_handle(mt_process_pty_handle* handle) {
  if (handle == NULL) {
    return;
  }

  handle->pid = 0;
  handle->master_fd = -1;
}

static inline void mt_process_reset_read_result(mt_process_read_result* result) {
  if (result == NULL) {
    return;
  }

  result->ready = false;
  result->closed = false;
  result->data = NULL;
  result->len = 0;
}

static inline void mt_process_reset_wait_result(mt_process_wait_result* result) {
  if (result == NULL) {
    return;
  }

  result->ready = false;
  result->exit_status = 0;
  result->term_signal = 0;
}

#if defined(_WIN32)

static inline char*** mt_process_environ_accessor(void) {
  return NULL;
}

static inline uintptr_t mt_process_environ_length(void) {
  return 0;
}

static inline int mt_process_spawn_interactive(const char* file, char** args, char** env, const char* cwd, mt_process_spawn_handle* out_handle, mt_process_error* out_error) {
  (void) file;
  (void) args;
  (void) env;
  (void) cwd;
  mt_process_reset_spawn_handle(out_handle);
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "interactive process is not supported on Windows yet", NULL);
}

static inline int mt_process_spawn_pty(const char* file, char** args, char** env, const char* cwd, int columns, int rows, mt_process_pty_handle* out_handle, mt_process_error* out_error) {
  (void) file;
  (void) args;
  (void) env;
  (void) cwd;
  (void) columns;
  (void) rows;
  mt_process_reset_pty_handle(out_handle);
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "pty process is not supported on Windows yet", NULL);
}

static inline int mt_process_read_fd(int fd, int timeout_ms, mt_process_read_result* out_result, mt_process_error* out_error) {
  (void) fd;
  (void) timeout_ms;
  mt_process_reset_read_result(out_result);
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "interactive process I/O is not supported on Windows yet", NULL);
}

static inline int mt_process_write_fd(int fd, const char* data, uintptr_t len, uintptr_t* out_written, mt_process_error* out_error) {
  (void) fd;
  (void) data;
  (void) len;
  mt_process_reset_error(out_error);
  if (out_written != NULL) {
    *out_written = 0;
  }
  return mt_process_set_message(out_error, -1, "interactive process I/O is not supported on Windows yet", NULL);
}

static inline int mt_process_close_fd(int fd, mt_process_error* out_error) {
  (void) fd;
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "interactive process I/O is not supported on Windows yet", NULL);
}

static inline int mt_process_wait(int pid, mt_process_wait_result* out_result, mt_process_error* out_error) {
  (void) pid;
  mt_process_reset_wait_result(out_result);
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "interactive process waiting is not supported on Windows yet", NULL);
}

static inline int mt_process_try_wait(int pid, mt_process_wait_result* out_result, mt_process_error* out_error) {
  (void) pid;
  mt_process_reset_wait_result(out_result);
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "interactive process waiting is not supported on Windows yet", NULL);
}

static inline int mt_process_kill(int pid, int signal_number, mt_process_error* out_error) {
  (void) pid;
  (void) signal_number;
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "interactive process signals are not supported on Windows yet", NULL);
}

static inline int mt_process_pty_resize(int fd, int columns, int rows, mt_process_error* out_error) {
  (void) fd;
  (void) columns;
  (void) rows;
  mt_process_reset_error(out_error);
  return mt_process_set_message(out_error, -1, "pty resize is not supported on Windows yet", NULL);
}

#else

static inline void mt_process_close_fd_quiet(int* fd) {
  if (fd == NULL || *fd < 0) {
    return;
  }

  close(*fd);
  *fd = -1;
}

static inline int mt_process_set_fd_cloexec(int fd, mt_process_error* out_error, const char* prefix) {
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0) {
    return mt_process_set_message(out_error, errno, prefix, strerror(errno));
  }

  if (fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
    return mt_process_set_message(out_error, errno, prefix, strerror(errno));
  }

  return 0;
}

static inline int mt_process_read_exec_error(int error_fd, mt_process_error* out_error, const char* prefix) {
  int error_code = 0;
  ssize_t read_count;
  do {
    read_count = read(error_fd, &error_code, sizeof(error_code));
  } while (read_count < 0 && errno == EINTR);

  if (read_count > 0) {
    return mt_process_set_message(out_error, error_code, prefix, strerror(error_code));
  }

  return 0;
}

static inline int mt_process_execve_with_env(const char* file, char** args, char** env) {
  if (env != NULL) {
    return execvpe(file, args, env);
  }

  return execvp(file, args);
}

static inline void mt_process_child_fail(int error_fd, int error_code) {
  if (error_fd >= 0) {
    ssize_t written_count;
    do {
      written_count = write(error_fd, &error_code, sizeof(error_code));
    } while (written_count < 0 && errno == EINTR);
  }

  _exit(127);
}

static inline int mt_process_spawn_interactive(const char* file, char** args, char** env, const char* cwd, mt_process_spawn_handle* out_handle, mt_process_error* out_error) {
  int stdin_pipe[2] = { -1, -1 };
  int stdout_pipe[2] = { -1, -1 };
  int stderr_pipe[2] = { -1, -1 };
  int error_pipe[2] = { -1, -1 };
  mt_process_reset_spawn_handle(out_handle);
  mt_process_reset_error(out_error);

  if (file == NULL || args == NULL || args[0] == NULL) {
    return mt_process_set_message(out_error, -1, "process command cannot be empty", NULL);
  }

  if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0 || pipe(error_pipe) < 0) {
    mt_process_close_fd_quiet(&stdin_pipe[0]);
    mt_process_close_fd_quiet(&stdin_pipe[1]);
    mt_process_close_fd_quiet(&stdout_pipe[0]);
    mt_process_close_fd_quiet(&stdout_pipe[1]);
    mt_process_close_fd_quiet(&stderr_pipe[0]);
    mt_process_close_fd_quiet(&stderr_pipe[1]);
    mt_process_close_fd_quiet(&error_pipe[0]);
    mt_process_close_fd_quiet(&error_pipe[1]);
    return mt_process_set_message(out_error, errno, "process pipe creation failed", strerror(errno));
  }

  int cloexec_status = mt_process_set_fd_cloexec(error_pipe[1], out_error, "process exec error pipe setup failed");
  if (cloexec_status != 0) {
    mt_process_close_fd_quiet(&stdin_pipe[0]);
    mt_process_close_fd_quiet(&stdin_pipe[1]);
    mt_process_close_fd_quiet(&stdout_pipe[0]);
    mt_process_close_fd_quiet(&stdout_pipe[1]);
    mt_process_close_fd_quiet(&stderr_pipe[0]);
    mt_process_close_fd_quiet(&stderr_pipe[1]);
    mt_process_close_fd_quiet(&error_pipe[0]);
    mt_process_close_fd_quiet(&error_pipe[1]);
    return cloexec_status;
  }

  pid_t pid = fork();
  if (pid < 0) {
    mt_process_close_fd_quiet(&stdin_pipe[0]);
    mt_process_close_fd_quiet(&stdin_pipe[1]);
    mt_process_close_fd_quiet(&stdout_pipe[0]);
    mt_process_close_fd_quiet(&stdout_pipe[1]);
    mt_process_close_fd_quiet(&stderr_pipe[0]);
    mt_process_close_fd_quiet(&stderr_pipe[1]);
    mt_process_close_fd_quiet(&error_pipe[0]);
    mt_process_close_fd_quiet(&error_pipe[1]);
    return mt_process_set_message(out_error, errno, "process fork failed", strerror(errno));
  }

  if (pid == 0) {
    mt_process_close_fd_quiet(&error_pipe[0]);
    mt_process_close_fd_quiet(&stdin_pipe[1]);
    mt_process_close_fd_quiet(&stdout_pipe[0]);
    mt_process_close_fd_quiet(&stderr_pipe[0]);

    if (cwd != NULL && chdir(cwd) != 0) {
      mt_process_child_fail(error_pipe[1], errno);
    }

    if (dup2(stdin_pipe[0], STDIN_FILENO) < 0 || dup2(stdout_pipe[1], STDOUT_FILENO) < 0 || dup2(stderr_pipe[1], STDERR_FILENO) < 0) {
      mt_process_child_fail(error_pipe[1], errno);
    }

    mt_process_close_fd_quiet(&stdin_pipe[0]);
    mt_process_close_fd_quiet(&stdout_pipe[1]);
    mt_process_close_fd_quiet(&stderr_pipe[1]);

    mt_process_execve_with_env(file, args, env);
    mt_process_child_fail(error_pipe[1], errno);
  }

  mt_process_close_fd_quiet(&error_pipe[1]);
  mt_process_close_fd_quiet(&stdin_pipe[0]);
  mt_process_close_fd_quiet(&stdout_pipe[1]);
  mt_process_close_fd_quiet(&stderr_pipe[1]);

  int exec_status = mt_process_read_exec_error(error_pipe[0], out_error, "process exec failed");
  mt_process_close_fd_quiet(&error_pipe[0]);
  if (exec_status != 0) {
    int wait_status;
    waitpid(pid, &wait_status, 0);
    mt_process_close_fd_quiet(&stdin_pipe[1]);
    mt_process_close_fd_quiet(&stdout_pipe[0]);
    mt_process_close_fd_quiet(&stderr_pipe[0]);
    return exec_status;
  }

  out_handle->pid = (int) pid;
  out_handle->stdin_fd = stdin_pipe[1];
  out_handle->stdout_fd = stdout_pipe[0];
  out_handle->stderr_fd = stderr_pipe[0];
  return 0;
}

static inline int mt_process_spawn_pty(const char* file, char** args, char** env, const char* cwd, int columns, int rows, mt_process_pty_handle* out_handle, mt_process_error* out_error) {
  int master_fd = -1;
  int error_pipe[2] = { -1, -1 };
  mt_process_reset_pty_handle(out_handle);
  mt_process_reset_error(out_error);

  if (file == NULL || args == NULL || args[0] == NULL) {
    return mt_process_set_message(out_error, -1, "process command cannot be empty", NULL);
  }

  master_fd = posix_openpt(O_RDWR | O_NOCTTY);
  if (master_fd < 0) {
    return mt_process_set_message(out_error, errno, "pty master open failed", strerror(errno));
  }

  if (grantpt(master_fd) != 0 || unlockpt(master_fd) != 0) {
    mt_process_close_fd_quiet(&master_fd);
    return mt_process_set_message(out_error, errno, "pty master setup failed", strerror(errno));
  }

  if (pipe(error_pipe) < 0) {
    mt_process_close_fd_quiet(&master_fd);
    return mt_process_set_message(out_error, errno, "pty error pipe creation failed", strerror(errno));
  }

  int cloexec_status = mt_process_set_fd_cloexec(error_pipe[1], out_error, "pty exec error pipe setup failed");
  if (cloexec_status != 0) {
    mt_process_close_fd_quiet(&master_fd);
    mt_process_close_fd_quiet(&error_pipe[0]);
    mt_process_close_fd_quiet(&error_pipe[1]);
    return cloexec_status;
  }

  char* slave_name = ptsname(master_fd);
  if (slave_name == NULL) {
    int error_code = errno;
    mt_process_close_fd_quiet(&master_fd);
    mt_process_close_fd_quiet(&error_pipe[0]);
    mt_process_close_fd_quiet(&error_pipe[1]);
    return mt_process_set_message(out_error, error_code, "pty slave lookup failed", strerror(error_code));
  }

  pid_t pid = fork();
  if (pid < 0) {
    mt_process_close_fd_quiet(&master_fd);
    mt_process_close_fd_quiet(&error_pipe[0]);
    mt_process_close_fd_quiet(&error_pipe[1]);
    return mt_process_set_message(out_error, errno, "pty fork failed", strerror(errno));
  }

  if (pid == 0) {
    mt_process_close_fd_quiet(&error_pipe[0]);

    if (setsid() < 0) {
      mt_process_child_fail(error_pipe[1], errno);
    }

    int slave_fd = open(slave_name, O_RDWR);
    if (slave_fd < 0) {
      mt_process_child_fail(error_pipe[1], errno);
    }

    if (ioctl(slave_fd, TIOCSCTTY, 0) < 0) {
      mt_process_close_fd_quiet(&slave_fd);
      mt_process_child_fail(error_pipe[1], errno);
    }

    if (columns > 0 && rows > 0) {
      struct winsize window_size;
      memset(&window_size, 0, sizeof(window_size));
      window_size.ws_col = (unsigned short) columns;
      window_size.ws_row = (unsigned short) rows;
      if (ioctl(slave_fd, TIOCSWINSZ, &window_size) < 0) {
        mt_process_close_fd_quiet(&slave_fd);
        mt_process_child_fail(error_pipe[1], errno);
      }
    }

    if (cwd != NULL && chdir(cwd) != 0) {
      mt_process_close_fd_quiet(&slave_fd);
      mt_process_child_fail(error_pipe[1], errno);
    }

    if (dup2(slave_fd, STDIN_FILENO) < 0 || dup2(slave_fd, STDOUT_FILENO) < 0 || dup2(slave_fd, STDERR_FILENO) < 0) {
      mt_process_close_fd_quiet(&slave_fd);
      mt_process_child_fail(error_pipe[1], errno);
    }

    mt_process_close_fd_quiet(&master_fd);
    mt_process_close_fd_quiet(&slave_fd);

    mt_process_execve_with_env(file, args, env);
    mt_process_child_fail(error_pipe[1], errno);
  }

  mt_process_close_fd_quiet(&error_pipe[1]);
  int exec_status = mt_process_read_exec_error(error_pipe[0], out_error, "pty exec failed");
  mt_process_close_fd_quiet(&error_pipe[0]);
  if (exec_status != 0) {
    int wait_status;
    waitpid(pid, &wait_status, 0);
    mt_process_close_fd_quiet(&master_fd);
    return exec_status;
  }

  out_handle->pid = (int) pid;
  out_handle->master_fd = master_fd;
  return 0;
}

static inline int mt_process_read_fd(int fd, int timeout_ms, mt_process_read_result* out_result, mt_process_error* out_error) {
  mt_process_reset_read_result(out_result);
  mt_process_reset_error(out_error);

  if (fd < 0) {
    return mt_process_set_message(out_error, -1, "process stream is closed", NULL);
  }

  struct pollfd poll_state;
  memset(&poll_state, 0, sizeof(poll_state));
  poll_state.fd = fd;
  poll_state.events = POLLIN | POLLHUP;

  int poll_status;
  do {
    poll_status = poll(&poll_state, 1, timeout_ms);
  } while (poll_status < 0 && errno == EINTR);

  if (poll_status < 0) {
    return mt_process_set_message(out_error, errno, "process stream poll failed", strerror(errno));
  }

  if (poll_status == 0) {
    return 0;
  }

  char* buffer = (char*) malloc(4096);
  if (buffer == NULL) {
    return mt_process_set_message(out_error, UV_ENOMEM, "process stream read allocation failed", uv_strerror(UV_ENOMEM));
  }

  ssize_t read_count;
  do {
    read_count = read(fd, buffer, 4096);
  } while (read_count < 0 && errno == EINTR);

  if (read_count < 0) {
    int error_code = errno;
    free(buffer);
    if (error_code == EAGAIN || error_code == EWOULDBLOCK) {
      return 0;
    }
    if (error_code == EIO) {
      out_result->ready = true;
      out_result->closed = true;
      return 0;
    }
    return mt_process_set_message(out_error, error_code, "process stream read failed", strerror(error_code));
  }

  out_result->ready = true;
  if (read_count == 0) {
    out_result->closed = true;
    free(buffer);
    return 0;
  }

  out_result->data = buffer;
  out_result->len = (uintptr_t) read_count;
  return 0;
}

static inline int mt_process_write_fd(int fd, const char* data, uintptr_t len, uintptr_t* out_written, mt_process_error* out_error) {
  uintptr_t written_total = 0;
  mt_process_reset_error(out_error);
  if (out_written != NULL) {
    *out_written = 0;
  }

  if (fd < 0) {
    return mt_process_set_message(out_error, -1, "process stream is closed", NULL);
  }

  while (written_total < len) {
    ssize_t write_count;
    do {
      write_count = write(fd, data + written_total, len - written_total);
    } while (write_count < 0 && errno == EINTR);

    if (write_count < 0) {
      return mt_process_set_message(out_error, errno, "process stream write failed", strerror(errno));
    }

    written_total += (uintptr_t) write_count;
  }

  if (out_written != NULL) {
    *out_written = written_total;
  }
  return 0;
}

static inline int mt_process_close_fd(int fd, mt_process_error* out_error) {
  mt_process_reset_error(out_error);
  if (fd < 0) {
    return 0;
  }

  if (close(fd) != 0) {
    return mt_process_set_message(out_error, errno, "process stream close failed", strerror(errno));
  }

  return 0;
}

static inline int mt_process_wait_internal(int pid, int options, mt_process_wait_result* out_result, mt_process_error* out_error) {
  int status = 0;
  mt_process_reset_wait_result(out_result);
  mt_process_reset_error(out_error);

  if (pid <= 0) {
    return mt_process_set_message(out_error, -1, "process pid is invalid", NULL);
  }

  pid_t wait_status;
  do {
    wait_status = waitpid((pid_t) pid, &status, options);
  } while (wait_status < 0 && errno == EINTR);

  if (wait_status < 0) {
    return mt_process_set_message(out_error, errno, "process wait failed", strerror(errno));
  }

  if (wait_status == 0) {
    return 0;
  }

  out_result->ready = true;
  if (WIFEXITED(status)) {
    out_result->exit_status = (int64_t) WEXITSTATUS(status);
    out_result->term_signal = 0;
    return 0;
  }

  if (WIFSIGNALED(status)) {
    out_result->exit_status = 0;
    out_result->term_signal = WTERMSIG(status);
    return 0;
  }

  out_result->exit_status = 0;
  out_result->term_signal = 0;
  return 0;
}

static inline int mt_process_wait(int pid, mt_process_wait_result* out_result, mt_process_error* out_error) {
  return mt_process_wait_internal(pid, 0, out_result, out_error);
}

static inline int mt_process_try_wait(int pid, mt_process_wait_result* out_result, mt_process_error* out_error) {
  return mt_process_wait_internal(pid, WNOHANG, out_result, out_error);
}

static inline int mt_process_kill(int pid, int signal_number, mt_process_error* out_error) {
  mt_process_reset_error(out_error);
  if (pid <= 0) {
    return mt_process_set_message(out_error, -1, "process pid is invalid", NULL);
  }

  if (kill((pid_t) pid, signal_number) != 0) {
    return mt_process_set_message(out_error, errno, "process signal failed", strerror(errno));
  }

  return 0;
}

static inline int mt_process_pty_resize(int fd, int columns, int rows, mt_process_error* out_error) {
  struct winsize window_size;
  mt_process_reset_error(out_error);

  if (fd < 0) {
    return mt_process_set_message(out_error, -1, "process stream is closed", NULL);
  }

  if (columns <= 0 || rows <= 0) {
    return mt_process_set_message(out_error, -1, "pty size must be positive", NULL);
  }

  memset(&window_size, 0, sizeof(window_size));
  window_size.ws_col = (unsigned short) columns;
  window_size.ws_row = (unsigned short) rows;
  if (ioctl(fd, TIOCSWINSZ, &window_size) != 0) {
    return mt_process_set_message(out_error, errno, "pty resize failed", strerror(errno));
  }

  return 0;
}

static inline char*** mt_process_environ_accessor(void) {
  return &environ;
}

static inline uintptr_t mt_process_environ_length(void) {
  if (environ == NULL) {
    return 0;
  }
  uintptr_t count = 0;
  char** cursor = environ;
  while (*cursor != NULL) {
    count += 1;
    cursor += 1;
  }
  return count;
}

#endif

#endif
