# Bootstrap seeds

A seed is a prebuilt `mtc` binary that `tools/bootstrap.sh` uses as stage0 to
build the current compiler from source.  It exists so a fresh clone can build
the toolchain with only a C compiler — no Ruby.  The source build also needs the
vendored `third_party/` sources, which `mtc toolchain bootstrap` fetches once
(network required, then cached in the checkout).

## Layout

```
vendor/bootstrap/<platform>/mtc           the seed binary
vendor/bootstrap/<platform>/mtc.sha256    sha256sum output, verified on use
```

`<platform>` is `uname -s` lowercased plus `uname -m`, for example
`linux-x86_64`.  Only `linux-x86_64` is present today; a missing platform is a
hard error that names the expected path.

## Provenance

The checked-in `linux-x86_64` seed is the release build of the `0.5.0` tree,
sha256 `d0d8068188c0cc74ef60bac79822b4249f51d6341bd6e9482014ac209bfff5da`,
refreshed with:

```sh
tools/release.sh --refresh-seed
```

It is a **stage2** compiler whose code generation comes from Milk Tea; the
native bootstrap that produced it never invoked the archived Ruby host.  The
verification run (`tools/bootstrap.sh -j 4`) then proves the seed reaches a
fixed point and passes the self-tests.  The seed has the same runtime
requirements as the release: glibc 2.38+, zlib, and OpenSSL 3; libuv is linked
statically.

## Replacement policy

Replace the seed only when a release is cut, or when a language change makes
the current seed unable to compile `projects/mtc`.  A seed only needs to
compile the *source tree at its own commit*; newer language features are what
force a refresh.  Regenerate with the command above and update `mtc.sha256`.

Do not strip the binary or change profiles between seed and release without
refreshing the checksum.

## Bypassing the seed

`--bootstrap PATH` and `$MTC_BOOTSTRAP` take precedence and are not
checksum-verified.
