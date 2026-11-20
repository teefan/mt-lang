# Bootstrap seeds

A seed is a prebuilt `mtc` binary that `tools/bootstrap.sh` uses as stage0 to
build the current compiler from source.  It exists so a fresh clone can build
the toolchain with only a C compiler — no Ruby, no network.

## Layout

```
vendor/bootstrap/<platform>/mtc           the seed binary
vendor/bootstrap/<platform>/mtc.sha256    sha256sum output, verified on use
```

`<platform>` is `uname -s` lowercased plus `uname -m`, for example
`linux-x86_64`.  Only `linux-x86_64` is present today; a missing platform is a
hard error that names the expected path.

## Provenance

The checked-in `linux-x86_64` seed was built at commit `6a67c937` with:

```sh
tools/bootstrap.sh --stage 2 --profile release -j 16
cp build/stage2/mtc vendor/bootstrap/linux-x86_64/mtc
```

It is a **stage2** compiler — built by a stage1 compiler that was itself built
by the Ruby host — so its code generation comes from Milk Tea, not Ruby.  The
verification run (`tools/bootstrap.sh -j 16`) then proves the seed reaches a
fixed point.

## Replacement policy

Replace the seed only when a release is cut, or when a language change makes
the current seed unable to compile `projects/mtc`.  A seed only needs to
compile the *source tree at its own commit*; newer language features are what
force a refresh.  Regenerate with the command above and update `mtc.sha256`.

Do not strip the binary or change profiles between seed and release without
refreshing the checksum.

## Bypassing the seed

`--bootstrap PATH` and `$MTC_BOOTSTRAP` take precedence and are not
checksum-verified.  To build with the Ruby host, pass `--allow-ruby-host`.
