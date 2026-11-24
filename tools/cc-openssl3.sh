#!/bin/sh
# Build against the OpenSSL 3 ABI when the host also has OpenSSL 4.
#
# The release contract is libssl.so.3 (Ubuntu 24.04, Arch's `openssl-3`
# package).  On a host whose default `-lssl` is the 4.x soname, the archive
# would otherwise require libssl.so.4 and fail the clean-container smoke.
# Hosts whose default is already OpenSSL 3 fall through to plain `cc`.
#
# `tools/release.sh` selects this wrapper when $CC is unset; pass an explicit
# CC to override.

if [ -d /usr/include/openssl-3 ] && [ -e /usr/lib/openssl-3/libssl.so ]; then
    exec cc -I/usr/include/openssl-3 -L/usr/lib/openssl-3 "$@"
fi

exec cc "$@"
