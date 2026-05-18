#ifndef MT_TLS_SUPPORT_H
#define MT_TLS_SUPPORT_H

#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <netdb.h>
#include <netinet/in.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509_vfy.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct mt_tls_bytes {
  uint8_t* data;
  uintptr_t len;
} mt_tls_bytes;

typedef struct mt_tls_error {
  int code;
  char* message_data;
  uintptr_t message_len;
} mt_tls_error;

static inline void mt_tls_reset_bytes(mt_tls_bytes* value) {
  if (value == NULL) {
    return;
  }

  value->data = NULL;
  value->len = 0;
}

static inline void mt_tls_reset_error(mt_tls_error* error) {
  if (error == NULL) {
    return;
  }

  error->code = 0;
  error->message_data = NULL;
  error->message_len = 0;
}

static inline int mt_tls_set_message(mt_tls_error* error, int code, const char* prefix, const char* detail) {
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

static inline int mt_tls_set_errno_error(mt_tls_error* error, int code, const char* prefix) {
  return mt_tls_set_message(error, code == 0 ? -1 : code, prefix, strerror(code == 0 ? errno : code));
}

static inline int mt_tls_set_gai_error(mt_tls_error* error, int code, const char* prefix) {
  return mt_tls_set_message(error, code == 0 ? -1 : code, prefix, gai_strerror(code));
}

static inline int mt_tls_set_ssl_error(mt_tls_error* error, int code, const char* prefix) {
  unsigned long ssl_code = ERR_peek_last_error();
  if (ssl_code != 0) {
    char detail[256];
    ERR_error_string_n(ssl_code, detail, sizeof(detail));
    return mt_tls_set_message(error, code == 0 ? -1 : code, prefix, detail);
  }

  return mt_tls_set_message(error, code == 0 ? -1 : code, prefix, "OpenSSL reported an unspecified failure");
}

static inline const char* mt_tls_env_or_null(const char* name) {
  const char* value = getenv(name);
  if (value == NULL || value[0] == '\0') {
    return NULL;
  }

  return value;
}

static inline int mt_tls_load_verify_paths(SSL_CTX* ctx, mt_tls_error* out_error) {
  const char* cert_file = mt_tls_env_or_null("SSL_CERT_FILE");
  const char* cert_dir = mt_tls_env_or_null("SSL_CERT_DIR");

  if (cert_file != NULL || cert_dir != NULL) {
    if (SSL_CTX_load_verify_locations(ctx, cert_file, cert_dir) == 1) {
      return 0;
    }

    return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
  }

  if (SSL_CTX_set_default_verify_paths(ctx) == 1) {
    return 0;
  }

  return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
}

static inline int mt_tls_host_is_ip_literal(const char* host) {
  struct in_addr ipv4_address;
  struct in6_addr ipv6_address;

  return inet_pton(AF_INET, host, &ipv4_address) == 1 || inet_pton(AF_INET6, host, &ipv6_address) == 1;
}

static inline int mt_tls_configure_peer_name(SSL* ssl, const char* host, mt_tls_error* out_error) {
  if (mt_tls_host_is_ip_literal(host)) {
    X509_VERIFY_PARAM* verify_param = SSL_get0_param(ssl);
    if (verify_param == NULL) {
      return mt_tls_set_message(out_error, -1, "tls connect failed", "missing certificate verification parameters");
    }

    if (X509_VERIFY_PARAM_set1_ip_asc(verify_param, host) != 1) {
      return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
    }

    return 0;
  }

  if (SSL_set_tlsext_host_name(ssl, host) != 1) {
    return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
  }

  if (SSL_set1_host(ssl, host) != 1) {
    return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
  }

  return 0;
}

static inline int mt_tls_grow_buffer(uint8_t** data, size_t* capacity, size_t minimum_capacity, mt_tls_error* out_error) {
  size_t next_capacity = *capacity == 0 ? 4096 : *capacity;
  while (next_capacity < minimum_capacity) {
    if (next_capacity > SIZE_MAX / 2) {
      if (next_capacity >= minimum_capacity) {
        break;
      }

      return mt_tls_set_message(out_error, -1, "tls read failed", "response exceeds addressable memory");
    }

    next_capacity *= 2;
  }

  uint8_t* resized = (uint8_t*) realloc(*data, next_capacity);
  if (resized == NULL) {
    return mt_tls_set_message(out_error, -1, "tls read failed", "out of memory");
  }

  *data = resized;
  *capacity = next_capacity;
  return 0;
}

static inline void mt_tls_cleanup(SSL_CTX* ctx, SSL* ssl, int fd, struct addrinfo* addresses) {
  if (addresses != NULL) {
    freeaddrinfo(addresses);
  }

  if (ssl != NULL) {
    SSL_shutdown(ssl);
    SSL_free(ssl);
  }

  if (ctx != NULL) {
    SSL_CTX_free(ctx);
  }

  if (fd >= 0) {
    close(fd);
  }
}

static inline int mt_tls_exchange(const char* host, int port, const uint8_t* request_data, uintptr_t request_len, mt_tls_bytes* out_response, mt_tls_error* out_error) {
  mt_tls_reset_bytes(out_response);
  mt_tls_reset_error(out_error);

  if (host == NULL || host[0] == '\0') {
    return mt_tls_set_message(out_error, -1, "tls connect failed", "host is required");
  }
  if (port <= 0 || port > 65535) {
    return mt_tls_set_message(out_error, -1, "tls connect failed", "port must be between 1 and 65535");
  }
  if (request_len != 0 && request_data == NULL) {
    return mt_tls_set_message(out_error, -1, "tls write failed", "missing request data");
  }

  SSL_CTX* ctx = NULL;
  SSL* ssl = NULL;
  struct addrinfo hints;
  struct addrinfo* addresses = NULL;
  int fd = -1;
  uint8_t* response_data = NULL;
  size_t response_len = 0;
  size_t response_capacity = 0;
  int last_errno = 0;
  char service[16];

  ERR_clear_error();
  ctx = SSL_CTX_new(TLS_client_method());
  if (ctx == NULL) {
    return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
  }

  SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
#ifdef SSL_OP_IGNORE_UNEXPECTED_EOF
  SSL_CTX_set_options(ctx, SSL_OP_IGNORE_UNEXPECTED_EOF);
#endif

  if (mt_tls_load_verify_paths(ctx, out_error) != 0) {
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return out_error == NULL ? -1 : out_error->code;
  }

  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;

  snprintf(service, sizeof(service), "%d", port);
  int status = getaddrinfo(host, service, &hints, &addresses);
  if (status != 0) {
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_gai_error(out_error, status, "tls connect failed");
  }

  for (struct addrinfo* current = addresses; current != NULL; current = current->ai_next) {
    fd = socket(current->ai_family, current->ai_socktype, current->ai_protocol);
    if (fd < 0) {
      last_errno = errno;
      continue;
    }

    if (connect(fd, current->ai_addr, current->ai_addrlen) == 0) {
      break;
    }

    last_errno = errno;
    close(fd);
    fd = -1;
  }

  if (fd < 0) {
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_errno_error(out_error, last_errno, "tls connect failed");
  }

  ERR_clear_error();
  ssl = SSL_new(ctx);
  if (ssl == NULL) {
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
  }

  if (mt_tls_configure_peer_name(ssl, host, out_error) != 0) {
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return out_error == NULL ? -1 : out_error->code;
  }

  if (SSL_set_fd(ssl, fd) != 1) {
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_ssl_error(out_error, -1, "tls connect failed");
  }

  ERR_clear_error();
  int connect_status = SSL_connect(ssl);
  if (connect_status != 1) {
    long verify_status = SSL_get_verify_result(ssl);
    if (verify_status != X509_V_OK) {
      mt_tls_cleanup(ctx, ssl, fd, addresses);
      return mt_tls_set_message(out_error, (int) verify_status, "tls connect failed", X509_verify_cert_error_string(verify_status));
    }

    int ssl_error = SSL_get_error(ssl, connect_status);
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_ssl_error(out_error, ssl_error, "tls connect failed");
  }

  long verify_status = SSL_get_verify_result(ssl);
  if (verify_status != X509_V_OK) {
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_message(out_error, (int) verify_status, "tls connect failed", X509_verify_cert_error_string(verify_status));
  }

  size_t request_offset = 0;
  while (request_offset < request_len) {
    size_t written = 0;
    ERR_clear_error();
    int write_status = SSL_write_ex(ssl, request_data + request_offset, (size_t) (request_len - request_offset), &written);
    if (write_status == 1) {
      request_offset += written;
      continue;
    }

    int ssl_error = SSL_get_error(ssl, write_status);
    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) {
      continue;
    }

    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_ssl_error(out_error, ssl_error, "tls write failed");
  }

  while (1) {
    if (response_capacity - response_len < 2048) {
      size_t minimum_capacity = response_len + 4096;
      if (mt_tls_grow_buffer(&response_data, &response_capacity, minimum_capacity, out_error) != 0) {
        free(response_data);
        mt_tls_cleanup(ctx, ssl, fd, addresses);
        return out_error == NULL ? -1 : out_error->code;
      }
    }

    size_t available = response_capacity - response_len;
    int read_limit = available > (size_t) INT_MAX ? INT_MAX : (int) available;
    ERR_clear_error();
    int read_status = SSL_read(ssl, response_data + response_len, read_limit);
    if (read_status > 0) {
      response_len += (size_t) read_status;
      continue;
    }

    int ssl_error = SSL_get_error(ssl, read_status);
    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) {
      continue;
    }
    if (ssl_error == SSL_ERROR_ZERO_RETURN) {
      break;
    }
    if (ssl_error == SSL_ERROR_SYSCALL && errno == 0) {
      break;
    }

    free(response_data);
    mt_tls_cleanup(ctx, ssl, fd, addresses);
    return mt_tls_set_ssl_error(out_error, ssl_error, "tls read failed");
  }

  mt_tls_cleanup(ctx, ssl, fd, addresses);

  if (response_len == 0) {
    free(response_data);
    response_data = NULL;
  }

  out_response->data = response_data;
  out_response->len = (uintptr_t) response_len;
  return 0;
}

#endif
