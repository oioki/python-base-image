# python-base-image

A distroless Python 3.13 base image built from scratch on Debian 13 (trixie).
Drop-in analog of `ghcr.io/getsentry/dhi/python:3.13-debian13`, designed as the
runtime base for Sentry services such as [snuba](https://github.com/getsentry/snuba).

## Images

| Tag | Description |
| --- | --- |
| `ghcr.io/oioki/python-base-image/python:3.13-debian13`     | `FROM scratch` + Python 3.13 + glibc/openssl/sqlite/lz4/... — no shell, no apt. |
| `ghcr.io/oioki/python-base-image/python:3.13-debian13-dev` | Same as above plus busybox-static (`sh`, `ls`, `cat`, `wget`, …) for debugging. |

Both images:

- Layout: `/opt/python/bin/python3`, `/opt/python/lib/python3.13/...`
- User: `nonroot` (UID/GID 65532, the conventional distroless UID), `HOME=/home/nonroot`
- `LD_LIBRARY_PATH=/opt/python/lib` so the loader finds libpython without needing `RPATH`
- CA bundle: `/etc/ssl/certs/ca-certificates.crt` (also exposed via `SSL_CERT_FILE`)
- Timezone DB: `/usr/share/zoneinfo`
- `ENTRYPOINT` is `python3` — override as needed
- `dbm.gnu` is unavailable (libgdbm is not shipped) — use `sqlite3` if you need a stdlib KV store

Built for `linux/amd64` and `linux/arm64`.

## Usage in snuba's Dockerfile

Replace the DHI references at the bottom of `Dockerfile`:

```dockerfile
FROM ghcr.io/oioki/python-base-image/python:3.13-debian13     AS application-distroless
# ...
FROM ghcr.io/oioki/python-base-image/python:3.13-debian13-dev AS application-distroless-debug
```

The rest of the snuba Dockerfile works unchanged — `distroless_prep` already
re-symlinks the venv's `python` to `/opt/python/bin/python3` and copies its own
`/etc/passwd`/`/etc/group` over the base image's.

## Local development

```sh
make build         # builds both variants for the native architecture
make test          # runs Python smoke tests inside each variant
make clean
```

Build args:

```sh
make build PYTHON_VERSION=3.13.12 DEBIAN_RELEASE=trixie TAG_BASE=3.13-debian13
```

## How it's built

`Dockerfile` is a multi-stage build:

1. `python-source` — pulls the official `python:${PYTHON_VERSION}-slim-${DEBIAN_RELEASE}`.
2. `rootfs-prod` — `debian:trixie-slim` with the runtime shared libs apt-installed;
   relocates Python to `/opt/python`, runs `ldconfig`, creates the `nonroot` user,
   sanity-tests the interpreter, then stages a curated `/rootfs` tree.
3. `rootfs-dev` — extends `rootfs-prod` with busybox-static and its applet symlinks.
4. `application-distroless` / `application-distroless-dev` — `FROM scratch`, with the
   staged rootfs copied wholesale.

The `rootfs` approach keeps the final image free of apt, /var, /sbin, and anything
else not explicitly listed.

## CI

`.github/workflows/build.yml` builds both variants for amd64 and arm64 on native
runners and assembles multi-arch manifests on push to `main`. Published tags:

- `:3.13-debian13` and `:3.13-debian13-dev` (floating)
- `:<sha>` and `:<sha>-dev` (immutable, traceable to a commit)
