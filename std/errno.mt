import std.c.errno as c

public type Code = int

public const NONE: Code = c.MT_ERRNO_CODES.MT_ERRNO_NONE
public const E2BIG: Code = c.MT_ERRNO_CODES.MT_ERRNO_E2BIG
public const EACCES: Code = c.MT_ERRNO_CODES.MT_ERRNO_EACCES
public const EAGAIN: Code = c.MT_ERRNO_CODES.MT_ERRNO_EAGAIN
public const EBADF: Code = c.MT_ERRNO_CODES.MT_ERRNO_EBADF
public const EBUSY: Code = c.MT_ERRNO_CODES.MT_ERRNO_EBUSY
public const ECONNREFUSED: Code = c.MT_ERRNO_CODES.MT_ERRNO_ECONNREFUSED
public const ECONNRESET: Code = c.MT_ERRNO_CODES.MT_ERRNO_ECONNRESET
public const EEXIST: Code = c.MT_ERRNO_CODES.MT_ERRNO_EEXIST
public const EFAULT: Code = c.MT_ERRNO_CODES.MT_ERRNO_EFAULT
public const EHOSTUNREACH: Code = c.MT_ERRNO_CODES.MT_ERRNO_EHOSTUNREACH
public const EINPROGRESS: Code = c.MT_ERRNO_CODES.MT_ERRNO_EINPROGRESS
public const EINTR: Code = c.MT_ERRNO_CODES.MT_ERRNO_EINTR
public const EINVAL: Code = c.MT_ERRNO_CODES.MT_ERRNO_EINVAL
public const EIO: Code = c.MT_ERRNO_CODES.MT_ERRNO_EIO
public const EISCONN: Code = c.MT_ERRNO_CODES.MT_ERRNO_EISCONN
public const EISDIR: Code = c.MT_ERRNO_CODES.MT_ERRNO_EISDIR
public const EMFILE: Code = c.MT_ERRNO_CODES.MT_ERRNO_EMFILE
public const ENAMETOOLONG: Code = c.MT_ERRNO_CODES.MT_ERRNO_ENAMETOOLONG
public const ENOENT: Code = c.MT_ERRNO_CODES.MT_ERRNO_ENOENT
public const ENOMEM: Code = c.MT_ERRNO_CODES.MT_ERRNO_ENOMEM
public const ENOSPC: Code = c.MT_ERRNO_CODES.MT_ERRNO_ENOSPC
public const ENOTCONN: Code = c.MT_ERRNO_CODES.MT_ERRNO_ENOTCONN
public const ENOTDIR: Code = c.MT_ERRNO_CODES.MT_ERRNO_ENOTDIR
public const ENOTEMPTY: Code = c.MT_ERRNO_CODES.MT_ERRNO_ENOTEMPTY
public const EPERM: Code = c.MT_ERRNO_CODES.MT_ERRNO_EPERM
public const EPIPE: Code = c.MT_ERRNO_CODES.MT_ERRNO_EPIPE
public const EROFS: Code = c.MT_ERRNO_CODES.MT_ERRNO_EROFS
public const ESRCH: Code = c.MT_ERRNO_CODES.MT_ERRNO_ESRCH
public const ETIMEDOUT: Code = c.MT_ERRNO_CODES.MT_ERRNO_ETIMEDOUT
public const EXDEV: Code = c.MT_ERRNO_CODES.MT_ERRNO_EXDEV

public foreign function current() -> Code = c.mt_errno_get
public foreign function set_current(value: Code) -> void = c.mt_errno_set
public foreign function message(error: Code) -> cstr? = c.mt_errno_strerror


public function clear() -> void:
    set_current(NONE)
    return


public function current_message() -> cstr?:
    return message(current())
