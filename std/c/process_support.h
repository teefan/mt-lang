#ifndef MT_PROCESS_SUPPORT_H
#define MT_PROCESS_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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

#endif
