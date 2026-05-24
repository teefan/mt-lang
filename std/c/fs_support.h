#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#ifndef MT_FS_SUPPORT_H
#define MT_FS_SUPPORT_H

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <uv.h>

typedef struct mt_fs_string {
  char* data;
  uintptr_t len;
} mt_fs_string;

typedef struct mt_fs_entries {
  char** data;
  uintptr_t* lengths;
  uintptr_t count;
} mt_fs_entries;

typedef struct mt_fs_error {
  int code;
  char* message_data;
  uintptr_t message_len;
} mt_fs_error;

typedef struct mt_fs_metadata {
  int kind;
  int mode;
  uintptr_t size;
  intptr_t modified_seconds;
  intptr_t modified_nanoseconds;
} mt_fs_metadata;

enum {
  MT_FS_KIND_NONE = 0,
  MT_FS_KIND_FILE = 1,
  MT_FS_KIND_DIRECTORY = 2,
  MT_FS_KIND_OTHER = 3,
};

static inline void mt_fs_reset_string(mt_fs_string* value) {
  if (value == NULL) {
    return;
  }

  value->data = NULL;
  value->len = 0;
}

static inline void mt_fs_reset_entries(mt_fs_entries* value) {
  if (value == NULL) {
    return;
  }

  value->data = NULL;
  value->lengths = NULL;
  value->count = 0;
}

static inline void mt_fs_reset_error(mt_fs_error* error) {
  if (error == NULL) {
    return;
  }

  error->code = 0;
  error->message_data = NULL;
  error->message_len = 0;
}

static inline void mt_fs_reset_metadata(mt_fs_metadata* value) {
  if (value == NULL) {
    return;
  }

  value->kind = MT_FS_KIND_NONE;
  value->mode = 0;
  value->size = 0;
  value->modified_seconds = 0;
  value->modified_nanoseconds = 0;
}

static inline int mt_fs_set_message(mt_fs_error* error, int code, const char* prefix, const char* detail) {
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

static inline int mt_fs_set_errno_error(mt_fs_error* error, int code, const char* prefix) {
  return mt_fs_set_message(error, code, prefix, strerror(code));
}

static inline int mt_fs_set_uv_error(mt_fs_error* error, uv_fs_t* req, int uv_code, const char* prefix) {
  int code = req == NULL ? 0 : uv_fs_get_system_error(req);
  if (code < 0) {
    code = -code;
  }
  if (code == 0) {
    code = uv_code < 0 ? -uv_code : uv_code;
  }
  return mt_fs_set_message(error, code, prefix, uv_strerror(uv_code));
}

static inline bool mt_fs_is_separator(char value) {
  return value == '/' || value == '\\';
}

static inline int mt_fs_root_length(const char* path) {
  if (path == NULL || path[0] == '\0') {
    return 0;
  }

  if (mt_fs_is_separator(path[0])) {
    if (mt_fs_is_separator(path[1])) {
      return 2;
    }
    return 1;
  }

  if (((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':') {
    if (mt_fs_is_separator(path[2])) {
      return 3;
    }
    return 2;
  }

  return 0;
}

static inline void mt_fs_release_entry_buffers(char** data, uintptr_t* lengths, uintptr_t count) {
  if (data != NULL) {
    for (uintptr_t index = 0; index < count; index += 1) {
      free(data[index]);
    }
  }

  free(data);
  free(lengths);
}

static inline int mt_fs_close_file(uv_file descriptor, mt_fs_error* out_error, const char* prefix) {
  uv_fs_t close_req;
  int close_status = uv_fs_close(NULL, &close_req, descriptor, NULL);
  if (close_status < 0) {
    int result = mt_fs_set_uv_error(out_error, &close_req, close_status, prefix);
    uv_fs_req_cleanup(&close_req);
    return result;
  }
  uv_fs_req_cleanup(&close_req);
  return 0;
}

static inline int mt_fs_path_kind(const char* path) {
  if (path == NULL || path[0] == '\0') {
    return MT_FS_KIND_NONE;
  }

  uv_fs_t req;
  int status = uv_fs_stat(NULL, &req, path, NULL);
  if (status < 0) {
    uv_fs_req_cleanup(&req);
    return MT_FS_KIND_NONE;
  }

  const uv_stat_t* info = uv_fs_get_statbuf(&req);
  int kind = MT_FS_KIND_OTHER;
  if (info != NULL) {
    if (S_ISREG(info->st_mode)) {
      kind = MT_FS_KIND_FILE;
    } else if (S_ISDIR(info->st_mode)) {
      kind = MT_FS_KIND_DIRECTORY;
    }
  }

  uv_fs_req_cleanup(&req);
  return kind;
}

static inline int mt_fs_get_metadata(const char* path, mt_fs_metadata* out_metadata, mt_fs_error* out_error) {
  mt_fs_reset_metadata(out_metadata);
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs metadata failed", "path cannot be empty");
  }

  uv_fs_t req;
  int status = uv_fs_lstat(NULL, &req, path, NULL);
  if (status < 0) {
    int result = mt_fs_set_uv_error(out_error, &req, status, "fs metadata failed");
    uv_fs_req_cleanup(&req);
    return result;
  }

  const uv_stat_t* info = uv_fs_get_statbuf(&req);
  if (info == NULL) {
    uv_fs_req_cleanup(&req);
    return mt_fs_set_message(out_error, EIO, "fs metadata failed", "missing stat data");
  }

  out_metadata->mode = (int) (info->st_mode & 07777);
  out_metadata->size = (uintptr_t) info->st_size;
  out_metadata->modified_seconds = (intptr_t) info->st_mtim.tv_sec;
  out_metadata->modified_nanoseconds = (intptr_t) info->st_mtim.tv_nsec;
  if (S_ISREG(info->st_mode)) {
    out_metadata->kind = MT_FS_KIND_FILE;
  } else if (S_ISDIR(info->st_mode)) {
    out_metadata->kind = MT_FS_KIND_DIRECTORY;
  } else {
    out_metadata->kind = MT_FS_KIND_OTHER;
  }

  uv_fs_req_cleanup(&req);
  return 0;
}

static inline int mt_fs_read_text(const char* path, mt_fs_string* out_text, mt_fs_error* out_error) {
  mt_fs_reset_string(out_text);
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs read failed", "path cannot be empty");
  }

  uv_fs_t open_req;
  int open_status = uv_fs_open(NULL, &open_req, path, O_RDONLY, 0, NULL);
  if (open_status < 0) {
    int result = mt_fs_set_uv_error(out_error, &open_req, open_status, "fs read failed");
    uv_fs_req_cleanup(&open_req);
    return result;
  }

  uv_file descriptor = (uv_file) open_status;
  uv_fs_req_cleanup(&open_req);

  uintptr_t capacity = 0;
  char* buffer_data = NULL;
  const uintptr_t chunk_size = 65536;
  intptr_t offset = 0;

  while (true) {
    uintptr_t needed = (uintptr_t) offset + chunk_size;
    if (needed > capacity) {
      uintptr_t new_capacity = capacity == 0 ? chunk_size : capacity;
      while (new_capacity < needed) {
        if (new_capacity > (UINTPTR_MAX / 2)) {
          int close_status = mt_fs_close_file(descriptor, out_error, "fs read failed");
          free(buffer_data);
          return close_status != 0
            ? close_status
            : mt_fs_set_message(out_error, EOVERFLOW, "fs read failed", "file is too large");
        }
        new_capacity *= 2;
      }

      char* resized = (char*) realloc(buffer_data, (size_t) new_capacity);
      if (resized == NULL) {
        int close_status = mt_fs_close_file(descriptor, out_error, "fs read failed");
        free(buffer_data);
        return close_status != 0
          ? close_status
          : mt_fs_set_errno_error(out_error, ENOMEM, "fs read failed");
      }

      buffer_data = resized;
      capacity = new_capacity;
    }

    uv_buf_t buffer = uv_buf_init(buffer_data + offset, (unsigned int) chunk_size);
    uv_fs_t read_req;
    int read_status = uv_fs_read(NULL, &read_req, descriptor, &buffer, 1, offset, NULL);
    if (read_status < 0) {
      int result = mt_fs_set_uv_error(out_error, &read_req, read_status, "fs read failed");
      uv_fs_req_cleanup(&read_req);
      mt_fs_close_file(descriptor, out_error, "fs read failed");
      free(buffer_data);
      return result;
    }

    uv_fs_req_cleanup(&read_req);
    if (read_status == 0) {
      break;
    }

    offset += (intptr_t) read_status;
    if ((uintptr_t) offset > (UINTPTR_MAX - chunk_size)) {
      int close_status = mt_fs_close_file(descriptor, out_error, "fs read failed");
      free(buffer_data);
      return close_status != 0
        ? close_status
        : mt_fs_set_message(out_error, EOVERFLOW, "fs read failed", "file is too large");
    }
  }

  if (offset == 0) {
    free(buffer_data);
    buffer_data = NULL;
  } else if ((uintptr_t) offset != capacity) {
    char* sized = (char*) realloc(buffer_data, (size_t) offset);
    if (sized != NULL) {
      buffer_data = sized;
    }
  }

  int close_status = mt_fs_close_file(descriptor, out_error, "fs read failed");
  if (close_status != 0) {
    free(buffer_data);
    return close_status;
  }

  out_text->data = buffer_data;
  out_text->len = (uintptr_t) offset;
  return 0;
}

static inline int mt_fs_read_bytes(const char* path, mt_fs_string* out_bytes, mt_fs_error* out_error) {
  return mt_fs_read_text(path, out_bytes, out_error);
}

static inline int mt_fs_write_text(const char* path, const char* data, uintptr_t len, mt_fs_error* out_error) {
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs write failed", "path cannot be empty");
  }
  if (len != 0 && data == NULL) {
    return mt_fs_set_message(out_error, -1, "fs write failed", "missing input data");
  }

  uv_fs_t open_req;
  int open_status = uv_fs_open(NULL, &open_req, path, O_WRONLY | O_CREAT | O_TRUNC, 0666, NULL);
  if (open_status < 0) {
    int result = mt_fs_set_uv_error(out_error, &open_req, open_status, "fs write failed");
    uv_fs_req_cleanup(&open_req);
    return result;
  }

  uv_file descriptor = (uv_file) open_status;
  uv_fs_req_cleanup(&open_req);

  uintptr_t written_total = 0;
  intptr_t offset = 0;
  while (written_total < len) {
    uintptr_t remaining = len - written_total;
    unsigned int chunk = remaining > 65536 ? 65536U : (unsigned int) remaining;
    uv_buf_t buffer = uv_buf_init((char*) (data + written_total), chunk);
    uv_fs_t write_req;
    int write_status = uv_fs_write(NULL, &write_req, descriptor, &buffer, 1, offset, NULL);
    if (write_status < 0) {
      int result = mt_fs_set_uv_error(out_error, &write_req, write_status, "fs write failed");
      uv_fs_req_cleanup(&write_req);
      mt_fs_close_file(descriptor, out_error, "fs write failed");
      return result;
    }
    if (write_status == 0) {
      uv_fs_req_cleanup(&write_req);
      mt_fs_close_file(descriptor, out_error, "fs write failed");
      return mt_fs_set_message(out_error, EIO, "fs write failed", "short write");
    }

    uv_fs_req_cleanup(&write_req);
    written_total += (uintptr_t) write_status;
    offset += (intptr_t) write_status;
  }

  return mt_fs_close_file(descriptor, out_error, "fs write failed");
}

static inline int mt_fs_write_bytes(const char* path, const uint8_t* data, uintptr_t len, mt_fs_error* out_error) {
  return mt_fs_write_text(path, (const char*) data, len, out_error);
}

static inline int mt_fs_remove(const char* path, mt_fs_error* out_error) {
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs remove failed", "path cannot be empty");
  }

  uv_fs_t req;
  int status = uv_fs_unlink(NULL, &req, path, NULL);
  if (status < 0) {
    int unlink_code = status;
    uv_fs_req_cleanup(&req);
    if (unlink_code == UV_EISDIR || unlink_code == UV_EPERM) {
      status = uv_fs_rmdir(NULL, &req, path, NULL);
      if (status < 0) {
        int result = mt_fs_set_uv_error(out_error, &req, status, "fs remove failed");
        uv_fs_req_cleanup(&req);
        return result;
      }
      uv_fs_req_cleanup(&req);
      return 0;
    }

    return mt_fs_set_message(out_error, -unlink_code, "fs remove failed", uv_strerror(unlink_code));
  }

  uv_fs_req_cleanup(&req);
  return 0;
}

static inline int mt_fs_rename(const char* source_path, const char* target_path, mt_fs_error* out_error) {
  mt_fs_reset_error(out_error);

  if (source_path == NULL || source_path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs rename failed", "source path cannot be empty");
  }
  if (target_path == NULL || target_path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs rename failed", "target path cannot be empty");
  }

  uv_fs_t req;
  int status = uv_fs_rename(NULL, &req, source_path, target_path, NULL);
  if (status < 0) {
    int result = mt_fs_set_uv_error(out_error, &req, status, "fs rename failed");
    uv_fs_req_cleanup(&req);
    return result;
  }

  uv_fs_req_cleanup(&req);
  return 0;
}

static inline int mt_fs_set_permissions(const char* path, int mode, mt_fs_error* out_error) {
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs set permissions failed", "path cannot be empty");
  }

  uv_fs_t req;
  int status = uv_fs_chmod(NULL, &req, path, mode, NULL);
  if (status < 0) {
    int result = mt_fs_set_uv_error(out_error, &req, status, "fs set permissions failed");
    uv_fs_req_cleanup(&req);
    return result;
  }

  uv_fs_req_cleanup(&req);
  return 0;
}

static inline int mt_fs_ensure_directory(const char* path, mt_fs_error* out_error) {
  uv_fs_t mkdir_req;
  int status = uv_fs_mkdir(NULL, &mkdir_req, path, 0777, NULL);
  if (status == 0) {
    uv_fs_req_cleanup(&mkdir_req);
    return 0;
  }

  if (status == UV_EEXIST) {
    uv_fs_req_cleanup(&mkdir_req);
    uv_fs_t stat_req;
    int stat_status = uv_fs_stat(NULL, &stat_req, path, NULL);
    if (stat_status == 0) {
      const uv_stat_t* info = uv_fs_get_statbuf(&stat_req);
      bool is_directory = info != NULL && S_ISDIR(info->st_mode);
      uv_fs_req_cleanup(&stat_req);
      if (is_directory) {
        return 0;
      }
    } else {
      uv_fs_req_cleanup(&stat_req);
    }
  } else {
    int result = mt_fs_set_uv_error(out_error, &mkdir_req, status, "fs create directories failed");
    uv_fs_req_cleanup(&mkdir_req);
    return result;
  }

  return mt_fs_set_message(out_error, EEXIST, "fs create directories failed", "path exists and is not a directory");
}

static inline int mt_fs_create_directories(const char* path, mt_fs_error* out_error) {
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs create directories failed", "path cannot be empty");
  }

  size_t len = strlen(path);
  char* copy = (char*) malloc(len + 1);
  if (copy == NULL) {
    return mt_fs_set_errno_error(out_error, ENOMEM, "fs create directories failed");
  }

  memcpy(copy, path, len + 1);

  int root = mt_fs_root_length(copy);
  size_t index = (size_t) root;
  while (copy[index] != '\0' && mt_fs_is_separator(copy[index])) {
    index += 1;
  }

  while (true) {
    while (copy[index] != '\0' && !mt_fs_is_separator(copy[index])) {
      index += 1;
    }

    char saved = copy[index];
    copy[index] = '\0';

    if (copy[0] != '\0' && !(index == (size_t) root && root > 0)) {
      int ensure_status = mt_fs_ensure_directory(copy, out_error);
      if (ensure_status != 0) {
        free(copy);
        return ensure_status;
      }
    }

    if (saved == '\0') {
      break;
    }

    copy[index] = saved;
    index += 1;
    while (copy[index] != '\0' && mt_fs_is_separator(copy[index])) {
      index += 1;
    }
  }

  free(copy);
  return 0;
}

static inline int mt_fs_current_directory(mt_fs_string* out_text, mt_fs_error* out_error) {
  mt_fs_reset_string(out_text);
  mt_fs_reset_error(out_error);

  size_t capacity = 256;
  while (true) {
    char* buffer = (char*) malloc(capacity);
    if (buffer == NULL) {
      return mt_fs_set_errno_error(out_error, ENOMEM, "fs current directory failed");
    }

    size_t size = capacity;
    int status = uv_cwd(buffer, &size);
    if (status == 0) {
      out_text->data = buffer;
      out_text->len = (uintptr_t) size;
      return 0;
    }

    free(buffer);
    if (status != UV_ENOBUFS) {
      return mt_fs_set_message(out_error, -status, "fs current directory failed", uv_strerror(status));
    }

    if (capacity > ((size_t) UINTPTR_MAX) / 2) {
      return mt_fs_set_message(out_error, ENOMEM, "fs current directory failed", "path too long");
    }

    capacity *= 2;
  }
}

static inline int mt_fs_temporary_directory(mt_fs_string* out_text, mt_fs_error* out_error) {
  mt_fs_reset_string(out_text);
  mt_fs_reset_error(out_error);

  size_t capacity = 256;
  while (true) {
    char* buffer = (char*) malloc(capacity);
    if (buffer == NULL) {
      return mt_fs_set_errno_error(out_error, ENOMEM, "fs temporary directory failed");
    }

    size_t size = capacity;
    int status = uv_os_tmpdir(buffer, &size);
    if (status == 0) {
      out_text->data = buffer;
      out_text->len = (uintptr_t) size;
      return 0;
    }

    free(buffer);
    if (status != UV_ENOBUFS) {
      return mt_fs_set_message(out_error, -status, "fs temporary directory failed", uv_strerror(status));
    }

    if (capacity > ((size_t) UINTPTR_MAX) / 2) {
      return mt_fs_set_message(out_error, ENOMEM, "fs temporary directory failed", "path too long");
    }

    capacity *= 2;
  }
}

static inline int mt_fs_canonicalize(const char* path, mt_fs_string* out_text, mt_fs_error* out_error) {
  mt_fs_reset_string(out_text);
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs canonicalize failed", "path cannot be empty");
  }

  uv_fs_t req;
  int status = uv_fs_realpath(NULL, &req, path, NULL);
  if (status < 0) {
    int result = mt_fs_set_uv_error(out_error, &req, status, "fs canonicalize failed");
    uv_fs_req_cleanup(&req);
    return result;
  }

  const char* resolved = (const char*) req.ptr;
  if (resolved == NULL) {
    uv_fs_req_cleanup(&req);
    return mt_fs_set_message(out_error, EIO, "fs canonicalize failed", "missing realpath result");
  }

  size_t resolved_len = strlen(resolved);
  char* copied = NULL;
  if (resolved_len != 0) {
    copied = (char*) malloc(resolved_len);
    if (copied == NULL) {
      uv_fs_req_cleanup(&req);
      return mt_fs_set_errno_error(out_error, ENOMEM, "fs canonicalize failed");
    }
    memcpy(copied, resolved, resolved_len);
  }

  uv_fs_req_cleanup(&req);
  out_text->data = copied;
  out_text->len = (uintptr_t) resolved_len;
  return 0;
}

static inline int mt_fs_create_temporary_directory(const char* parent_dir,
                                                   const char* prefix,
                                                   mt_fs_string* out_path,
                                                   mt_fs_error* out_error) {
  mt_fs_reset_string(out_path);
  mt_fs_reset_error(out_error);

  if (parent_dir == NULL || parent_dir[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs create temporary directory failed", "parent directory cannot be empty");
  }
  if (prefix == NULL || prefix[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs create temporary directory failed", "prefix cannot be empty");
  }

  if (mt_fs_path_kind(parent_dir) != MT_FS_KIND_DIRECTORY) {
    return mt_fs_set_message(out_error, ENOENT, "fs create temporary directory failed", "parent directory does not exist");
  }

  size_t parent_len = strlen(parent_dir);
  size_t prefix_len = strlen(prefix);
  bool needs_separator = parent_len != 0 && !mt_fs_is_separator(parent_dir[parent_len - 1]);
  size_t template_len = parent_len + (needs_separator ? 1 : 0) + prefix_len + 7;

  char* template_path = (char*) malloc(template_len + 1);
  if (template_path == NULL) {
    return mt_fs_set_errno_error(out_error, ENOMEM, "fs create temporary directory failed");
  }

  size_t offset = 0;
  memcpy(template_path + offset, parent_dir, parent_len);
  offset += parent_len;
  if (needs_separator) {
    template_path[offset] = '/';
    offset += 1;
  }
  memcpy(template_path + offset, prefix, prefix_len);
  offset += prefix_len;
  memcpy(template_path + offset, "-XXXXXX", 7);
  offset += 7;
  template_path[offset] = '\0';

  uv_fs_t mkdtemp_req;
  int status = uv_fs_mkdtemp(NULL, &mkdtemp_req, template_path, NULL);
  if (status < 0) {
    int result = mt_fs_set_uv_error(out_error, &mkdtemp_req, status, "fs create temporary directory failed");
    uv_fs_req_cleanup(&mkdtemp_req);
    free(template_path);
    return result;
  }

  const char* created_source = mkdtemp_req.path != NULL ? mkdtemp_req.path : template_path;
  size_t created_len = strlen(created_source);
  char* created_path = NULL;
  if (created_len != 0) {
    created_path = (char*) malloc(created_len);
    if (created_path == NULL) {
      uv_fs_req_cleanup(&mkdtemp_req);
      free(template_path);
      return mt_fs_set_errno_error(out_error, ENOMEM, "fs create temporary directory failed");
    }
    memcpy(created_path, created_source, created_len);
  }

  uv_fs_req_cleanup(&mkdtemp_req);
  free(template_path);

  out_path->data = created_path;
  out_path->len = (uintptr_t) created_len;
  return 0;
}

static inline int mt_fs_create_temporary_file(const char* parent_dir,
                                              const char* prefix,
                                              const char* suffix,
                                              mt_fs_string* out_path,
                                              mt_fs_error* out_error) {
  mt_fs_reset_string(out_path);
  mt_fs_reset_error(out_error);

  if (parent_dir == NULL || parent_dir[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs create temporary file failed", "parent directory cannot be empty");
  }
  if (prefix == NULL || prefix[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs create temporary file failed", "prefix cannot be empty");
  }

  if (mt_fs_path_kind(parent_dir) != MT_FS_KIND_DIRECTORY) {
    return mt_fs_set_message(out_error, ENOENT, "fs create temporary file failed", "parent directory does not exist");
  }

  size_t parent_len = strlen(parent_dir);
  size_t prefix_len = strlen(prefix);
  size_t suffix_len = suffix == NULL ? 0 : strlen(suffix);
  bool needs_separator = parent_len != 0 && !mt_fs_is_separator(parent_dir[parent_len - 1]);
  size_t template_len = parent_len + (needs_separator ? 1 : 0) + prefix_len + 7;

  char* template_path = (char*) malloc(template_len + 1);
  if (template_path == NULL) {
    return mt_fs_set_errno_error(out_error, ENOMEM, "fs create temporary file failed");
  }

  size_t offset = 0;
  memcpy(template_path + offset, parent_dir, parent_len);
  offset += parent_len;
  if (needs_separator) {
    template_path[offset] = '/';
    offset += 1;
  }
  memcpy(template_path + offset, prefix, prefix_len);
  offset += prefix_len;
  memcpy(template_path + offset, "-XXXXXX", 7);
  offset += 7;
  template_path[offset] = '\0';

  uv_fs_t mkstemp_req;
  int descriptor = uv_fs_mkstemp(NULL, &mkstemp_req, template_path, NULL);
  if (descriptor < 0) {
    int result = mt_fs_set_uv_error(out_error, &mkstemp_req, descriptor, "fs create temporary file failed");
    uv_fs_req_cleanup(&mkstemp_req);
    free(template_path);
    return result;
  }

  const char* created_source = mkstemp_req.path != NULL ? mkstemp_req.path : template_path;
  size_t created_len = strlen(created_source);
  char* created_path = (char*) malloc(created_len + 1);
  if (created_path == NULL) {
    uv_fs_req_cleanup(&mkstemp_req);
    mt_fs_close_file((uv_file) descriptor, out_error, "fs create temporary file failed");
    uv_fs_t cleanup_req;
    uv_fs_unlink(NULL, &cleanup_req, created_source, NULL);
    uv_fs_req_cleanup(&cleanup_req);
    free(template_path);
    return mt_fs_set_errno_error(out_error, ENOMEM, "fs create temporary file failed");
  }
  memcpy(created_path, created_source, created_len + 1);

  uv_fs_req_cleanup(&mkstemp_req);
  free(template_path);

  if (mt_fs_close_file((uv_file) descriptor, out_error, "fs create temporary file failed") != 0) {
    uv_fs_t cleanup_req;
    uv_fs_unlink(NULL, &cleanup_req, created_path, NULL);
    uv_fs_req_cleanup(&cleanup_req);
    free(created_path);
    return out_error->code == 0 ? -1 : out_error->code;
  }

  if (suffix_len == 0) {
    out_path->data = created_path;
    out_path->len = (uintptr_t) created_len;
    return 0;
  }

  size_t base_len = created_len;
  size_t final_len = base_len + suffix_len;
  char* final_path = (char*) malloc(final_len + 1);
  if (final_path == NULL) {
    uv_fs_t cleanup_req;
    uv_fs_unlink(NULL, &cleanup_req, created_path, NULL);
    uv_fs_req_cleanup(&cleanup_req);
    free(created_path);
    return mt_fs_set_errno_error(out_error, ENOMEM, "fs create temporary file failed");
  }

  memcpy(final_path, created_path, base_len);
  memcpy(final_path + base_len, suffix, suffix_len);
  final_path[final_len] = '\0';

  uv_fs_t rename_req;
  int rename_status = uv_fs_rename(NULL, &rename_req, created_path, final_path, NULL);
  if (rename_status < 0) {
    int result = mt_fs_set_uv_error(out_error, &rename_req, rename_status, "fs create temporary file failed");
    uv_fs_req_cleanup(&rename_req);
    uv_fs_t cleanup_req;
    uv_fs_unlink(NULL, &cleanup_req, created_path, NULL);
    uv_fs_req_cleanup(&cleanup_req);
    free(created_path);
    free(final_path);
    return result;
  }
  uv_fs_req_cleanup(&rename_req);

  free(created_path);
  out_path->data = final_path;
  out_path->len = (uintptr_t) final_len;
  return 0;
}

static inline int mt_fs_list_entries(const char* path, mt_fs_entries* out_entries, mt_fs_error* out_error) {
  mt_fs_reset_entries(out_entries);
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs list entries failed", "path cannot be empty");
  }

  uv_fs_t scandir_req;
  int status = uv_fs_scandir(NULL, &scandir_req, path, 0, NULL);
  if (status < 0) {
    int result = mt_fs_set_uv_error(out_error, &scandir_req, status, "fs list entries failed");
    uv_fs_req_cleanup(&scandir_req);
    return result;
  }

  uintptr_t capacity = status > 0 ? (uintptr_t) status : 8;
  uintptr_t count = 0;
  char** data = NULL;
  uintptr_t* lengths = NULL;

  data = (char**) malloc((size_t) (capacity * sizeof(char*)));
  lengths = (uintptr_t*) malloc((size_t) (capacity * sizeof(uintptr_t)));
  if (data == NULL || lengths == NULL) {
    free(data);
    free(lengths);
    uv_fs_req_cleanup(&scandir_req);
    return mt_fs_set_errno_error(out_error, ENOMEM, "fs list entries failed");
  }

  while (true) {
    uv_dirent_t entry;
    int next_status = uv_fs_scandir_next(&scandir_req, &entry);
    if (next_status == UV_EOF) {
      break;
    }
    if (next_status < 0) {
      mt_fs_release_entry_buffers(data, lengths, count);
      uv_fs_req_cleanup(&scandir_req);
      return mt_fs_set_message(out_error, -next_status, "fs list entries failed", uv_strerror(next_status));
    }

    if (entry.name == NULL) {
      continue;
    }
    if ((strcmp(entry.name, ".") == 0) || (strcmp(entry.name, "..") == 0)) {
      continue;
    }

    if (count == capacity) {
      uintptr_t new_capacity = capacity * 2;
      char** new_data = (char**) malloc((size_t) (new_capacity * sizeof(char*)));
      uintptr_t* new_lengths = (uintptr_t*) malloc((size_t) (new_capacity * sizeof(uintptr_t)));
      if (new_data == NULL || new_lengths == NULL) {
        free(new_data);
        free(new_lengths);
        mt_fs_release_entry_buffers(data, lengths, count);
        uv_fs_req_cleanup(&scandir_req);
        return mt_fs_set_errno_error(out_error, ENOMEM, "fs list entries failed");
      }

      memcpy(new_data, data, (size_t) (count * sizeof(char*)));
      memcpy(new_lengths, lengths, (size_t) (count * sizeof(uintptr_t)));
      free(data);
      free(lengths);
      data = new_data;
      lengths = new_lengths;
      capacity = new_capacity;
    }

    size_t entry_len = strlen(entry.name);
    char* copied = NULL;
    if (entry_len != 0) {
      copied = (char*) malloc(entry_len);
      if (copied == NULL) {
        mt_fs_release_entry_buffers(data, lengths, count);
        uv_fs_req_cleanup(&scandir_req);
        return mt_fs_set_errno_error(out_error, ENOMEM, "fs list entries failed");
      }
      memcpy(copied, entry.name, entry_len);
    }

    data[count] = copied;
    lengths[count] = (uintptr_t) entry_len;
    count += 1;
  }

  uv_fs_req_cleanup(&scandir_req);
  out_entries->data = data;
  out_entries->lengths = lengths;
  out_entries->count = count;
  return 0;
}

#endif
