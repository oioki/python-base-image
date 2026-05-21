IMAGE ?= ghcr.io/oioki/python-base-image/python
PYTHON_VERSION ?= 3.13.12
DEBIAN_RELEASE ?= trixie
TAG_BASE ?= 3.13-debian13

BUILD_ARGS := --build-arg PYTHON_VERSION=$(PYTHON_VERSION) \
              --build-arg DEBIAN_RELEASE=$(DEBIAN_RELEASE)

.PHONY: build build-prod build-dev test test-prod test-dev clean

build: build-prod build-dev

build-prod:
	docker buildx build $(BUILD_ARGS) \
		--target application-distroless \
		--tag $(IMAGE):$(TAG_BASE) \
		--load .

build-dev:
	docker buildx build $(BUILD_ARGS) \
		--target application-distroless-dev \
		--tag $(IMAGE):$(TAG_BASE)-dev \
		--load .

test: test-prod test-dev

# Smoke tests — bypass ENTRYPOINT since the prod image has no shell.
test-prod:
	docker run --rm --entrypoint /opt/python/bin/python3 $(IMAGE):$(TAG_BASE) \
		-c "import ssl, sqlite3, zlib, bz2, lzma, hashlib, ctypes, _socket; \
		    print('prod ok:', ssl.OPENSSL_VERSION)"

test-dev:
	docker run --rm --entrypoint /bin/sh $(IMAGE):$(TAG_BASE)-dev \
		-c "/opt/python/bin/python3 -c 'import ssl; print(\"dev ok:\", ssl.OPENSSL_VERSION)' && \
		    ls /bin/busybox && echo busybox ok"

clean:
	-docker image rm $(IMAGE):$(TAG_BASE) $(IMAGE):$(TAG_BASE)-dev
