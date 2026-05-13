#ifndef MT_LANG_ERRNO_BINDGEN_H
#define MT_LANG_ERRNO_BINDGEN_H

#include <errno.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

enum MT_ERRNO_CODES {
    MT_ERRNO_NONE = 0,
    MT_ERRNO_E2BIG = E2BIG,
    MT_ERRNO_EACCES = EACCES,
    MT_ERRNO_EAGAIN = EAGAIN,
    MT_ERRNO_EBADF = EBADF,
    MT_ERRNO_EBUSY = EBUSY,
    MT_ERRNO_ECONNREFUSED = ECONNREFUSED,
    MT_ERRNO_ECONNRESET = ECONNRESET,
    MT_ERRNO_EEXIST = EEXIST,
    MT_ERRNO_EFAULT = EFAULT,
    MT_ERRNO_EHOSTUNREACH = EHOSTUNREACH,
    MT_ERRNO_EINPROGRESS = EINPROGRESS,
    MT_ERRNO_EINTR = EINTR,
    MT_ERRNO_EINVAL = EINVAL,
    MT_ERRNO_EIO = EIO,
    MT_ERRNO_EISCONN = EISCONN,
    MT_ERRNO_EISDIR = EISDIR,
    MT_ERRNO_EMFILE = EMFILE,
    MT_ERRNO_ENAMETOOLONG = ENAMETOOLONG,
    MT_ERRNO_ENOENT = ENOENT,
    MT_ERRNO_ENOMEM = ENOMEM,
    MT_ERRNO_ENOSPC = ENOSPC,
    MT_ERRNO_ENOTCONN = ENOTCONN,
    MT_ERRNO_ENOTDIR = ENOTDIR,
    MT_ERRNO_ENOTEMPTY = ENOTEMPTY,
    MT_ERRNO_EPERM = EPERM,
    MT_ERRNO_EPIPE = EPIPE,
    MT_ERRNO_EROFS = EROFS,
    MT_ERRNO_ESRCH = ESRCH,
    MT_ERRNO_ETIMEDOUT = ETIMEDOUT,
    MT_ERRNO_EXDEV = EXDEV,
};

static inline int mt_errno_get(void) { return errno; }
static inline void mt_errno_set(int value) { errno = value; }
static inline const char *mt_errno_strerror(int value) { return strerror(value); }

#ifdef __cplusplus
}
#endif

#endif
