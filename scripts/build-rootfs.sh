#!/usr/bin/env bash
# Build /rootfs by selectively copying from the build container's filesystem.
#
# This is the opposite of the obvious "rm -rf the cruft" approach. Pruning in
# place means every subsequent helper (grep, find, cp, ldconfig) trips over
# missing libraries the prune just removed — libpcre2 takes out grep, libacl
# takes out cp, libselinux takes out find. Copy-only sidesteps that entirely:
# the build container stays whole, and /rootfs grows to contain exactly the
# shared-library closure we care about plus a small set of structural files.
#
# Closure seed:
#   1. /opt/python/bin/python3 and every .so under /opt/python
#   2. dlopen-only libs (nss_*, gconv/*) that ldd cannot statically discover
#   3. libs downstream wheels routinely link against but CPython itself does
#      not (libstdc++ for any C++/Rust+cc-built wheel)
# ldd is transitive, so a single pass yields the full closure.

set -euxo pipefail

# libpython sits in /opt/python/lib, which isn't on the loader's default
# search path. Exporting LD_LIBRARY_PATH means ldd (used below for the closure
# walk) resolves it correctly without needing an ld.so.cache regen. The final
# image's ENV sets the same value, so build- and run-time paths match exactly.
export LD_LIBRARY_PATH=/opt/python/lib

multiarch=$(basename /usr/lib/*-linux-gnu)   # aarch64-linux-gnu | x86_64-linux-gnu
src_libdir="/usr/lib/$multiarch"

{
    echo /opt/python/bin/python3
    find /opt/python -name '*.so*' -not -type d
    ls "$src_libdir"/libnss_*.so*    2>/dev/null || true
    ls "$src_libdir"/libstdc++.so.*  2>/dev/null || true
    # glibc compatibility stubs — pre-2.34 these were separate libraries,
    # now everything is in libc.so.6, but third-party wheels routinely
    # still record DT_NEEDED entries for the legacy SONAMEs. Without
    # these stubs you get "libpthread.so.0: cannot open shared object"
    # the moment a wheel like confluent_kafka loads. On arm64 trixie
    # these don't exist on disk and the globs silently expand to nothing.
    ls "$src_libdir"/libpthread.so.*  2>/dev/null || true
    ls "$src_libdir"/libdl.so.*       2>/dev/null || true
    ls "$src_libdir"/librt.so.*       2>/dev/null || true
    ls "$src_libdir"/libutil.so.*     2>/dev/null || true
    ls "$src_libdir"/libresolv.so.*   2>/dev/null || true
    ls "$src_libdir"/libnsl.so.*      2>/dev/null || true
    find "$src_libdir/gconv" -name '*.so' 2>/dev/null || true
} | sort -u > /tmp/seeds

{
    cat /tmp/seeds
    xargs -a /tmp/seeds -r ldd 2>/dev/null \
        | awk '{
              for (i=1; i<=NF; i++)
                  if ($i ~ /^\//) { sub(/:$/, "", $i); print $i }
          }'
} > /tmp/keep.raw

# Normalise: ldd reports through /lib -> /usr/lib symlinks and unversioned
# .so symlinks. Keep both the literal and the realpath so a $src_libdir
# file matches whether ldd mentioned its symlink form or its target form.
while IFS= read -r p; do
    echo "$p"
    readlink -f -- "$p" 2>/dev/null || true
done < /tmp/keep.raw | sort -u > /tmp/keep

# Lay out /rootfs.
mkdir -p /rootfs/etc /rootfs/usr/lib /rootfs/opt /rootfs/home /rootfs/tmp
chmod 1777 /rootfs/tmp

# Files and dirs we want verbatim. Anything not listed here (apt, dpkg,
# systemd, locale archives, perl, ...) is implicitly dropped.
verbatim=(
    /lib /lib64
    /usr/lib64
    /etc/ld.so.conf /etc/ld.so.conf.d
    /etc/passwd /etc/group /etc/shadow /etc/nsswitch.conf
    /etc/ssl /etc/ca-certificates.conf
    /usr/share/ca-certificates /usr/share/zoneinfo
    /opt/python /home/nonroot
)
for p in "${verbatim[@]}"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
        mkdir -p "$(dirname "/rootfs$p")"
        cp -a -- "$p" "/rootfs$p"
    fi
done

# Dynamic-linker symlinks that ELF binaries reference by hard-coded path
# (e.g. INTERP=/lib/ld-linux-aarch64.so.1 → /usr/lib/ld-linux-aarch64.so.1
# → aarch64-linux-gnu/ld-linux-aarch64.so.1). These live directly in /usr/lib,
# not in $multiarch/, so the closure walk doesn't see them.
for link in /usr/lib/ld-*; do
    if [ -e "$link" ] || [ -L "$link" ]; then
        cp -a -- "$link" /rootfs/usr/lib/
    fi
done

# Copy only the closure files from /usr/lib/$multiarch, preserving symlinks.
dst_libdir="/rootfs/usr/lib/$multiarch"
mkdir -p "$dst_libdir/gconv"
cp -a "$src_libdir/gconv/." "$dst_libdir/gconv/"

while IFS= read -r f; do
    case "$f" in
        "$src_libdir"/*)
            rel=${f#"$src_libdir/"}
            mkdir -p "$(dirname "$dst_libdir/$rel")"
            cp -a -- "$f" "$dst_libdir/$rel"
            ;;
    esac
done < /tmp/keep

# Generate /rootfs/etc/ld.so.cache so the loader can find libs under
# /usr/lib/$multiarch at runtime. (LD_LIBRARY_PATH covers libpython at
# /opt/python/lib; the multiarch path comes from /etc/ld.so.conf.d/*.conf.)
ldconfig -r /rootfs

# The upstream python:3.13-slim image builds CPython with --prefix=/usr/local,
# so /usr/local is baked into the binary as a fallback search path. When this
# image is used as a base for venvs (e.g. snuba's), pyvenv.cfg records
# `home = /usr/local/bin` and CPython's getpath logic falls back to
# /usr/local/lib/python3.13/ when the venv can't satisfy a stdlib lookup.
# Without this symlink that fallback is a dead end and Python aborts with
# "Failed to import encodings module".
mkdir -p /rootfs/usr
ln -sf /opt/python /rootfs/usr/local

rm -f /tmp/seeds /tmp/keep /tmp/keep.raw
