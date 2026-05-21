# Distroless Python base image, drop-in analog of
# ghcr.io/getsentry/dhi/python:3.13-debian13 used by snuba.
#
# Layout matches the DHI convention:
#   /opt/python/bin/python3       - interpreter
#   /opt/python/lib/python3.13/   - stdlib
#   /opt/python/lib/libpython3.13.so.1.0
#
# Two targets are exported:
#   application-distroless        - true distroless, scratch + python + libs
#   application-distroless-dev    - same + busybox-static for debugging

ARG PYTHON_VERSION=3.13.12
ARG DEBIAN_RELEASE=trixie

# --- Stage 1: Python source (taken from the official slim image) ---
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_RELEASE} AS python-source

# --- Stage 2: assemble a minimal rootfs with Python + runtime libs ---
FROM debian:${DEBIAN_RELEASE}-slim AS rootfs-prod

# Runtime shared libraries that CPython stdlib + common wheels link against.
# Kept intentionally small — anything snuba needs at import time should be here.
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libbz2-1.0 \
        libexpat1 \
        libffi8 \
        liblz4-1 \
        liblzma5 \
        libncursesw6 \
        libreadline8 \
        libsqlite3-0 \
        libssl3 \
        libtinfo6 \
        libuuid1 \
        tzdata \
        zlib1g; \
    rm -rf /var/lib/apt/lists/*

# Relocate Python from /usr/local (slim layout) to /opt/python (DHI layout).
COPY --from=python-source /usr/local /opt/python

# Trim things no service needs at runtime — keeps image small without
# pruning anything snuba imports.
RUN set -ex; \
    find /opt/python -depth -type d \
        \( -name '__pycache__' -o -name 'test' -o -name 'tests' \) \
        -exec rm -rf {} +; \
    rm -rf \
        /opt/python/lib/python3.13/idlelib \
        /opt/python/lib/python3.13/turtledemo \
        /opt/python/lib/python3.13/tkinter \
        /opt/python/share/man \
        /opt/python/share/doc

# Non-root user, UID 65532 — the conventional distroless UID. Snuba's runtime
# overwrites /etc/passwd with its own UID-1000 entry, so the value here is
# only relevant when consumers use this image directly.
RUN set -ex; \
    groupadd --system --gid 65532 nonroot; \
    useradd  --system --uid 65532 --gid 65532 \
             --home /home/nonroot --shell /sbin/nologin nonroot; \
    install -d -m 0755 -o nonroot -g nonroot /home/nonroot

# Hard fail if Python can't start or can't load any of the stdlib modules
# we just promised support for. We use LD_LIBRARY_PATH instead of ldconfig
# because that's the same mechanism the final image uses — keeps build and
# runtime paths identical and saves an ld.so.cache regeneration step.
RUN LD_LIBRARY_PATH=/opt/python/lib /opt/python/bin/python3 -c "\
import ssl, sqlite3, zlib, bz2, lzma, hashlib, ctypes, _socket, \
       readline, uuid, decimal, json; \
print('python ok:', ssl.OPENSSL_VERSION)"

# Build /rootfs by selectively copying CPython's shared-library closure plus
# a small curated set of structural files (see scripts/build-rootfs.sh).
# Copy-only (rather than delete-in-place) keeps the build container's tools
# functional through the whole operation. Bash is required for the script
# (dash, the default sh on Debian, lacks `read -d` and process substitution).
COPY scripts/build-rootfs.sh /tmp/build-rootfs.sh
RUN bash /tmp/build-rootfs.sh && rm /tmp/build-rootfs.sh

# --- Stage 3: same rootfs + busybox-static for the -dev variant ---
FROM rootfs-prod AS rootfs-dev

RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends busybox-static; \
    rm -rf /var/lib/apt/lists/*

# Drop busybox into the rootfs and symlink the standard applets.
# Avoids polluting /rootfs/usr/bin with anything else from the build image.
RUN set -ex; \
    install -d /rootfs/bin /rootfs/usr/bin; \
    install -m 0755 /bin/busybox /rootfs/bin/busybox; \
    for app in $(/bin/busybox --list); do \
        ln -sf /bin/busybox "/rootfs/usr/bin/$app"; \
    done; \
    ln -sf /bin/busybox /rootfs/bin/sh

# --- Final stages: FROM scratch + curated rootfs ---

FROM scratch AS application-distroless

COPY --from=rootfs-prod /rootfs/ /

ENV PATH=/opt/python/bin:/usr/bin:/bin \
    HOME=/home/nonroot \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LD_LIBRARY_PATH=/opt/python/lib \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 65532:65532
WORKDIR /home/nonroot
STOPSIGNAL SIGINT
ENTRYPOINT ["/opt/python/bin/python3"]

FROM scratch AS application-distroless-dev

COPY --from=rootfs-dev /rootfs/ /

ENV PATH=/opt/python/bin:/usr/bin:/bin \
    HOME=/home/nonroot \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LD_LIBRARY_PATH=/opt/python/lib \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 65532:65532
WORKDIR /home/nonroot
STOPSIGNAL SIGINT
ENTRYPOINT ["/opt/python/bin/python3"]
