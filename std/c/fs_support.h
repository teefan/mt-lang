#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#ifndef MT_FS_SUPPORT_H
#define MT_FS_SUPPORT_H

#include <dirent.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

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

static inline void mt_fs_release_entry_buffers(char** data, uintptr_t* lengths, uintptr_t count) {
  if (data != NULL) {
    for (uintptr_t index = 0; index < count; index += 1) {
      free(data[index]);
    }
  }

  free(data);
  free(lengths);
}

static inline int mt_fs_path_kind(const char* path) {
  if (path == NULL || path[0] == '\0') {
    return MT_FS_KIND_NONE;
  }

  struct stat info;
  if (stat(path, &info) != 0) {
    return MT_FS_KIND_NONE;
  }

  if (S_ISREG(info.st_mode)) {
    return MT_FS_KIND_FILE;
  }
  if (S_ISDIR(info.st_mode)) {
    return MT_FS_KIND_DIRECTORY;
  }
  return MT_FS_KIND_OTHER;
}

static inline int mt_fs_get_metadata(const char* path, mt_fs_metadata* out_metadata, mt_fs_error* out_error) {
  mt_fs_reset_metadata(out_metadata);
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs metadata failed", "path cannot be empty");
  }

  struct stat info;
  if (lstat(path, &info) != 0) {
    return mt_fs_set_errno_error(out_error, errno, "fs metadata failed");
  }

  out_metadata->mode = (int) (info.st_mode & 07777);
  out_metadata->size = (uintptr_t) info.st_size;
  out_metadata->modified_seconds = (intptr_t) info.st_mtim.tv_sec;
  out_metadata->modified_nanoseconds = (intptr_t) info.st_mtim.tv_nsec;
  if (S_ISREG(info.st_mode)) {
    out_metadata->kind = MT_FS_KIND_FILE;
  } else if (S_ISDIR(info.st_mode)) {
    out_metadata->kind = MT_FS_KIND_DIRECTORY;
  } else {
    out_metadata->kind = MT_FS_KIND_OTHER;
  }

  return 0;
}

static inline int mt_fs_read_text(const char* path, mt_fs_string* out_text, mt_fs_error* out_error) {
  mt_fs_reset_string(out_text);
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs read failed", "path cannot be empty");
  }

  FILE* file = fopen(path, "rb");
  if (file == NULL) {
    return mt_fs_set_errno_error(out_error, errno, "fs read failed");
  }

  if (fseek(file, 0, SEEK_END) != 0) {
    int code = errno;
    fclose(file);
    return mt_fs_set_errno_error(out_error, code, "fs read failed");
  }

  long size = ftell(file);
  if (size < 0) {
    int code = errno;
    fclose(file);
    return mt_fs_set_errno_error(out_error, code, "fs read failed");
  }

  if (fseek(file, 0, SEEK_SET) != 0) {
    int code = errno;
    fclose(file);
    return mt_fs_set_errno_error(out_error, code, "fs read failed");
  }

  char* data = NULL;
  if (size != 0) {
    data = (char*) malloc((size_t) size);
    if (data == NULL) {
      fclose(file);
      return mt_fs_set_errno_error(out_error, ENOMEM, "fs read failed");
    }

    size_t read_count = fread(data, 1, (size_t) size, file);
    if (read_count != (size_t) size) {
      int code = ferror(file) ? errno : EIO;
      free(data);
      fclose(file);
      return mt_fs_set_errno_error(out_error, code == 0 ? EIO : code, "fs read failed");
    }
  }

  if (fclose(file) != 0) {
    int code = errno;
    free(data);
    return mt_fs_set_errno_error(out_error, code, "fs read failed");
  }

  out_text->data = data;
  out_text->len = (uintptr_t) size;
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

  FILE* file = fopen(path, "wb");
  if (file == NULL) {
    return mt_fs_set_errno_error(out_error, errno, "fs write failed");
  }

  if (len != 0) {
    size_t written = fwrite(data, 1, (size_t) len, file);
    if (written != (size_t) len) {
      int code = ferror(file) ? errno : EIO;
      fclose(file);
      return mt_fs_set_errno_error(out_error, code == 0 ? EIO : code, "fs write failed");
    }
  }

  if (fclose(file) != 0) {
    return mt_fs_set_errno_error(out_error, errno, "fs write failed");
  }

  return 0;
}

static inline int mt_fs_write_bytes(const char* path, const uint8_t* data, uintptr_t len, mt_fs_error* out_error) {
  return mt_fs_write_text(path, (const char*) data, len, out_error);
}

static inline int mt_fs_remove(const char* path, mt_fs_error* out_error) {
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs remove failed", "path cannot be empty");
  }

  if (remove(path) != 0) {
    return mt_fs_set_errno_error(out_error, errno, "fs remove failed");
  }

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

  if (rename(source_path, target_path) != 0) {
    return mt_fs_set_errno_error(out_error, errno, "fs rename failed");
  }

  return 0;
}

static inline int mt_fs_set_permissions(const char* path, int mode, mt_fs_error* out_error) {
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs set permissions failed", "path cannot be empty");
  }

  if (chmod(path, (mode_t) mode) != 0) {
    return mt_fs_set_errno_error(out_error, errno, "fs set permissions failed");
  }

  return 0;
}

static inline int mt_fs_ensure_directory(const char* path, mt_fs_error* out_error) {
  if (mkdir(path, 0777) == 0) {
    return 0;
  }

  if (errno == EEXIST) {
    struct stat info;
    if (stat(path, &info) == 0 && S_ISDIR(info.st_mode)) {
      return 0;
    }
  }

  return mt_fs_set_errno_error(out_error, errno, "fs create directories failed");
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

  size_t index = copy[0] == '/' ? 1 : 0;
  while (copy[index] == '/') {
    index += 1;
  }

  while (true) {
    while (copy[index] != '/' && copy[index] != '\0') {
      index += 1;
    }

    char saved = copy[index];
    copy[index] = '\0';
    if (!(copy[0] == '/' && copy[1] == '\0') && copy[0] != '\0') {
      int status = mt_fs_ensure_directory(copy, out_error);
      if (status != 0) {
        free(copy);
        return status;
      }
    }

    if (saved == '\0') {
      break;
    }

    copy[index] = saved;
    index += 1;
    while (copy[index] == '/') {
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

    if (getcwd(buffer, capacity) != NULL) {
      out_text->data = buffer;
      out_text->len = (uintptr_t) strlen(buffer);
      return 0;
    }

    int code = errno;
    free(buffer);
    if (code != ERANGE) {
      return mt_fs_set_errno_error(out_error, code, "fs current directory failed");
    }

    if (capacity > ((size_t) UINTPTR_MAX) / 2) {
      return mt_fs_set_message(out_error, ENOMEM, "fs current directory failed", "path too long");
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

  char* resolved = realpath(path, NULL);
  if (resolved == NULL) {
    return mt_fs_set_errno_error(out_error, errno, "fs canonicalize failed");
  }

  out_text->data = resolved;
  out_text->len = (uintptr_t) strlen(resolved);
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
  bool needs_separator = parent_len != 0 && parent_dir[parent_len - 1] != '/';
  size_t template_len = parent_len + (needs_separator ? 1 : 0) + prefix_len + 7 + suffix_len;

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
  if (suffix_len != 0) {
    memcpy(template_path + offset, suffix, suffix_len);
    offset += suffix_len;
  }
  template_path[offset] = '\0';

  int descriptor = suffix_len == 0 ? mkstemp(template_path) : mkstemps(template_path, (int) suffix_len);
  if (descriptor < 0) {
    int code = errno;
    free(template_path);
    return mt_fs_set_errno_error(out_error, code, "fs create temporary file failed");
  }

  if (close(descriptor) != 0) {
    int code = errno;
    remove(template_path);
    free(template_path);
    return mt_fs_set_errno_error(out_error, code, "fs create temporary file failed");
  }

  out_path->data = template_path;
  out_path->len = (uintptr_t) strlen(template_path);
  return 0;
}

static inline int mt_fs_list_entries(const char* path, mt_fs_entries* out_entries, mt_fs_error* out_error) {
  mt_fs_reset_entries(out_entries);
  mt_fs_reset_error(out_error);

  if (path == NULL || path[0] == '\0') {
    return mt_fs_set_message(out_error, -1, "fs list entries failed", "path cannot be empty");
  }

  DIR* directory = opendir(path);
  if (directory == NULL) {
    return mt_fs_set_errno_error(out_error, errno, "fs list entries failed");
  }

  char** data = NULL;
  uintptr_t* lengths = NULL;
  uintptr_t count = 0;
  uintptr_t capacity = 0;

  errno = 0;
  while (true) {
    struct dirent* entry = readdir(directory);
    if (entry == NULL) {
      break;
    }

    if ((strcmp(entry->d_name, ".") == 0) || (strcmp(entry->d_name, "..") == 0)) {
      errno = 0;
      continue;
    }

    if (count == capacity) {
      uintptr_t new_capacity = capacity == 0 ? 8 : capacity * 2;
      char** new_data = (char**) malloc((size_t) (new_capacity * sizeof(char*)));
      uintptr_t* new_lengths = (uintptr_t*) malloc((size_t) (new_capacity * sizeof(uintptr_t)));
      if (new_data == NULL || new_lengths == NULL) {
        free(new_data);
        free(new_lengths);
        mt_fs_release_entry_buffers(data, lengths, count);
        closedir(directory);
        return mt_fs_set_errno_error(out_error, ENOMEM, "fs list entries failed");
      }

      if (count != 0) {
        memcpy(new_data, data, (size_t) (count * sizeof(char*)));
        memcpy(new_lengths, lengths, (size_t) (count * sizeof(uintptr_t)));
      }

      free(data);
      free(lengths);

      data = new_data;
      lengths = new_lengths;
      capacity = new_capacity;
    }

    size_t len = strlen(entry->d_name);
    char* copied = NULL;
    if (len != 0) {
      copied = (char*) malloc(len);
      if (copied == NULL) {
        mt_fs_release_entry_buffers(data, lengths, count);
        closedir(directory);
        return mt_fs_set_errno_error(out_error, ENOMEM, "fs list entries failed");
      }
      memcpy(copied, entry->d_name, len);
    }

    data[count] = copied;
    lengths[count] = (uintptr_t) len;
    count += 1;
    errno = 0;
  }

  int read_error = errno;
  if (closedir(directory) != 0) {
    int code = errno;
    mt_fs_release_entry_buffers(data, lengths, count);
    return mt_fs_set_errno_error(out_error, code, "fs list entries failed");
  }

  if (read_error != 0) {
    mt_fs_release_entry_buffers(data, lengths, count);
    return mt_fs_set_errno_error(out_error, read_error, "fs list entries failed");
  }

  out_entries->data = data;
  out_entries->lengths = lengths;
  out_entries->count = count;
  return 0;
}

#endif
