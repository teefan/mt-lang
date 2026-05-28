import std.c.errno as c

public type Code = int

public const NONE: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_NONE
public const E2BIG: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_E2BIG
public const EACCES: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EACCES
public const EAGAIN: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EAGAIN
public const EBADF: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EBADF
public const EBUSY: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EBUSY
public const ECONNREFUSED: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ECONNREFUSED
public const ECONNRESET: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ECONNRESET
public const EEXIST: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EEXIST
public const EFAULT: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EFAULT
public const EHOSTUNREACH: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EHOSTUNREACH
public const EINPROGRESS: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EINPROGRESS
public const EINTR: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EINTR
public const EINVAL: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EINVAL
public const EIO: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EIO
public const EISCONN: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EISCONN
public const EISDIR: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EISDIR
public const EMFILE: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EMFILE
public const ENAMETOOLONG: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ENAMETOOLONG
public const ENOENT: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ENOENT
public const ENOMEM: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ENOMEM
public const ENOSPC: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ENOSPC
public const ENOTCONN: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ENOTCONN
public const ENOTDIR: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ENOTDIR
public const ENOTEMPTY: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ENOTEMPTY
public const EPERM: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EPERM
public const EPIPE: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EPIPE
public const EROFS: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EROFS
public const ESRCH: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ESRCH
public const ETIMEDOUT: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_ETIMEDOUT
public const EXDEV: Code = int<-c.MT_ERRNO_CODES.MT_ERRNO_EXDEV

public foreign function current() -> Code = c.mt_errno_get
public foreign function set_current(value: Code) -> void = c.mt_errno_set
public foreign function message(error: Code) -> cstr? = c.mt_errno_strerror


public function clear() -> void:
    set_current(NONE)


public function current_message() -> cstr?:
    return message(current())
