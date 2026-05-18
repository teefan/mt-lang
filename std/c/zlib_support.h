#ifndef MT_ZLIB_SUPPORT_H
#define MT_ZLIB_SUPPORT_H

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct mt_zlib_bytes {
  uint8_t* data;
  uintptr_t len;
} mt_zlib_bytes;

typedef struct mt_zlib_error {
  int code;
  char* message_data;
  uintptr_t message_len;
} mt_zlib_error;

static inline void mt_zlib_reset_bytes(mt_zlib_bytes* value) {
  if (value == NULL) {
    return;
  }

  value->data = NULL;
  value->len = 0;
}

static inline void mt_zlib_reset_error(mt_zlib_error* error) {
  if (error == NULL) {
    return;
  }

  error->code = 0;
  error->message_data = NULL;
  error->message_len = 0;
}

static inline int mt_zlib_set_message(mt_zlib_error* error, int code, const char* prefix, const char* detail) {
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

static inline int mt_zlib_set_zlib_error(mt_zlib_error* error, int code, const char* prefix, const char* detail) {
  return mt_zlib_set_message(error, code, prefix, detail == NULL ? zError(code) : detail);
}

static inline int mt_gzip_compress(const uint8_t* data, uintptr_t len, int level, mt_zlib_bytes* out_bytes, mt_zlib_error* out_error) {
  mt_zlib_reset_bytes(out_bytes);
  mt_zlib_reset_error(out_error);

  if (len != 0 && data == NULL) {
    return mt_zlib_set_message(out_error, -1, "gzip compress failed", "missing input data");
  }
  if (level < -1 || level > 9) {
    return mt_zlib_set_message(out_error, -1, "gzip compress failed", "compression level must be between -1 and 9");
  }
  if (len > UINT_MAX || len > ULONG_MAX) {
    return mt_zlib_set_message(out_error, -1, "gzip compress failed", "input exceeds zlib range limits");
  }

  z_stream stream;
  memset(&stream, 0, sizeof(stream));

  int rc = deflateInit2(&stream, level, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY);
  if (rc != Z_OK) {
    return mt_zlib_set_zlib_error(out_error, rc, "gzip compress failed", stream.msg);
  }

  uLong bound = deflateBound(&stream, (uLong) len);
  if (bound > UINT_MAX) {
    deflateEnd(&stream);
    return mt_zlib_set_message(out_error, -1, "gzip compress failed", "compressed output exceeds zlib range limits");
  }

  size_t capacity = (size_t) bound;
  if (capacity < 64) {
    capacity = 64;
  }

  uint8_t* output = (uint8_t*) malloc(capacity);
  if (output == NULL) {
    deflateEnd(&stream);
    return mt_zlib_set_message(out_error, Z_MEM_ERROR, "gzip compress failed", "out of memory");
  }

  stream.next_in = len == 0 ? Z_NULL : (Bytef*) data;
  stream.avail_in = (uInt) len;
  stream.next_out = output;
  stream.avail_out = (uInt) capacity;

  rc = deflate(&stream, Z_FINISH);
  if (rc != Z_STREAM_END) {
    const char* detail = stream.msg;
    if (rc == Z_OK || rc == Z_BUF_ERROR) {
      detail = "compressed output buffer too small";
    }

    free(output);
    deflateEnd(&stream);
    return mt_zlib_set_zlib_error(out_error, rc == Z_OK ? Z_BUF_ERROR : rc, "gzip compress failed", detail);
  }

  size_t produced = (size_t) stream.total_out;
  rc = deflateEnd(&stream);
  if (rc != Z_OK) {
    free(output);
    return mt_zlib_set_zlib_error(out_error, rc, "gzip compress failed", NULL);
  }

  out_bytes->data = output;
  out_bytes->len = (uintptr_t) produced;
  return 0;
}

static inline int mt_gzip_decompress(const uint8_t* data, uintptr_t len, mt_zlib_bytes* out_bytes, mt_zlib_error* out_error) {
  mt_zlib_reset_bytes(out_bytes);
  mt_zlib_reset_error(out_error);

  if (len != 0 && data == NULL) {
    return mt_zlib_set_message(out_error, -1, "gzip decompress failed", "missing input data");
  }
  if (len > UINT_MAX) {
    return mt_zlib_set_message(out_error, -1, "gzip decompress failed", "input exceeds zlib range limits");
  }

  z_stream stream;
  memset(&stream, 0, sizeof(stream));

  int rc = inflateInit2(&stream, MAX_WBITS + 16);
  if (rc != Z_OK) {
    return mt_zlib_set_zlib_error(out_error, rc, "gzip decompress failed", stream.msg);
  }

  size_t capacity = (size_t) len;
  if (capacity < 64) {
    capacity = 64;
  }

  uint8_t* output = (uint8_t*) malloc(capacity);
  if (output == NULL) {
    inflateEnd(&stream);
    return mt_zlib_set_message(out_error, Z_MEM_ERROR, "gzip decompress failed", "out of memory");
  }

  stream.next_in = len == 0 ? Z_NULL : (Bytef*) data;
  stream.avail_in = (uInt) len;
  stream.next_out = output;
  stream.avail_out = (uInt) capacity;

  while (true) {
    rc = inflate(&stream, Z_NO_FLUSH);
    if (rc == Z_STREAM_END) {
      break;
    }

    if (rc == Z_OK) {
      if (stream.avail_out == 0) {
        size_t next_capacity = capacity > (size_t) (UINT_MAX / 2) ? (size_t) UINT_MAX : capacity * 2;
        if (next_capacity <= capacity) {
          free(output);
          inflateEnd(&stream);
          return mt_zlib_set_message(out_error, -1, "gzip decompress failed", "decompressed output exceeds zlib range limits");
        }

        uint8_t* resized = (uint8_t*) realloc(output, next_capacity);
        if (resized == NULL) {
          free(output);
          inflateEnd(&stream);
          return mt_zlib_set_message(out_error, Z_MEM_ERROR, "gzip decompress failed", "out of memory");
        }

        output = resized;
        stream.next_out = output + capacity;
        stream.avail_out = (uInt) (next_capacity - capacity);
        capacity = next_capacity;
      }

      continue;
    }

    free(output);
    inflateEnd(&stream);
    if (rc == Z_BUF_ERROR && stream.avail_in == 0) {
      return mt_zlib_set_message(out_error, rc, "gzip decompress failed", "truncated gzip stream");
    }

    return mt_zlib_set_zlib_error(out_error, rc, "gzip decompress failed", stream.msg);
  }

  size_t produced = (size_t) stream.total_out;
  rc = inflateEnd(&stream);
  if (rc != Z_OK) {
    free(output);
    return mt_zlib_set_zlib_error(out_error, rc, "gzip decompress failed", NULL);
  }

  if (produced == 0) {
    free(output);
    output = NULL;
  }

  out_bytes->data = output;
  out_bytes->len = (uintptr_t) produced;
  return 0;
}

#endif
