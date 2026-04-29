#ifndef MT_LANG_LIBUV_RUNTIME_HELPERS_H
#define MT_LANG_LIBUV_RUNTIME_HELPERS_H

#include <netinet/in.h>
#include <uv.h>

size_t mt_libuv_sockaddr_in_size(void);
int mt_libuv_sockaddr_in_port(const struct sockaddr_in* addr);

#ifdef MT_LIBUV_RUNTIME_HELPERS_IMPLEMENTATION

size_t mt_libuv_sockaddr_in_size(void) {
    return sizeof(struct sockaddr_in);
}

int mt_libuv_sockaddr_in_port(const struct sockaddr_in* addr) {
    if (addr == NULL) {
        return -1;
    }

    return (int) ntohs(addr->sin_port);
}

#endif

#endif
