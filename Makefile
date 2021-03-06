# Copyright 2014 The Cockroach Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License. See the AUTHORS file
# for names of contributors.
#
# Author: Andrew Bonventre (andybons@gmail.com)
# Author: Shawn Morel (shawnmorel@gmail.com)
# Author: Spencer Kimball (spencer.kimball@gmail.com)

# Cockroach build rules.
GO ?= go
# Allow setting of go build flags from the command line.
GOFLAGS := 
# Set to 1 to use static linking for all builds (including tests).
STATIC := $(STATIC)
# The cockroach image to be used for starting Docker containers
# during acceptance tests. Usually cockroachdb/cockroach{,-dev}
# depending on the context.
COCKROACH_IMAGE :=

RUN := run

# TODO(pmattis): Figure out where to clear the CGO_* variables when
# building "release" binaries.
export CGO_CFLAGS :=-g
export CGO_CXXFLAGS :=-g
export CGO_LDFLAGS :=-g

PKG        := "./..."
TESTS      := ".*"
TESTFLAGS  := -logtostderr -timeout 10s
RACEFLAGS  := -logtostderr -timeout 1m
BENCHFLAGS := -logtostderr -timeout 5m

ifeq ($(STATIC),1)
GOFLAGS  += -a -tags netgo -ldflags '-extldflags "-lm -lstdc++ -static"'
endif

all: build test

build: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildTag "$(shell git describe --dirty)"
build: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildTime "$(shell date -u '+%Y/%m/%d %H:%M:%S')"
build: LDFLAGS += -X github.com/cockroachdb/cockroach/util.buildDeps "$(shell GOPATH=${GOPATH} build/depvers.sh)"
build:
	$(GO) build $(GOFLAGS) -ldflags '$(LDFLAGS)' -v -i -o cockroach

# Similar to "testrace", we want to cache the build before running the
# tests.
test:
	$(GO) test $(GOFLAGS) -i $(PKG)
	$(GO) test $(GOFLAGS) -run $(TESTS) $(PKG) $(TESTFLAGS)

# "go test -i" builds dependencies and installs them into GOPATH/pkg, but does not run the
# tests. Run it as a part of "testrace" since race-enabled builds are not covered by
# "make build", and so they would be built from scratch every time (including the
# slow-to-compile cgo packages).
testrace:
	$(GO) test $(GOFLAGS) -race -i $(PKG)
	$(GO) test $(GOFLAGS) -race -run $(TESTS) $(PKG) $(RACEFLAGS)

bench:
	$(GO) test $(GOFLAGS) -run $(TESTS) -bench $(TESTS) $(PKG) $(BENCHFLAGS)

# Build, but do not run the tests. This is used to verify the deployable
# Docker image which comes without the build environment. See ./build/deploy
# for details.
# The test files are moved to the corresponding package. For example,
# PKG=./storage/engine will generate ./storage/engine/engine.test.
testbuild: TESTS := $(shell $(GO) list $(PKG))
testbuild: GOFLAGS += -c
testbuild:
	for p in $(TESTS); do \
	  NAME=$$(basename "$$p"); \
	  OUT="$$NAME.test"; \
	  DIR=$$($(GO) list -f {{.Dir}} ./...$$NAME); \
	  $(GO) test $(GOFLAGS) "$$p" $(TESTFLAGS) || break; \
	  if [ -f "$$OUT" ]; then \
		mv "$$OUT" "$$DIR" || break; \
	  fi \
	done


coverage: build
	$(GO) test $(GOFLAGS) -cover -run $(TESTS) $(PKG) $(TESTFLAGS)

acceptance:
# The first `stop` stops and cleans up any containers from previous runs.
	(cd $(RUN) && export COCKROACH_IMAGE="$(COCKROACH_IMAGE)" && \
	  ../build/build-docker-dev.sh && \
	  ./local-cluster.sh stop && \
	  ./local-cluster.sh start && \
	  ./local-cluster.sh stop)

clean:
	$(GO) clean -i github.com/cockroachdb/...
	find . -name '*.test' -type f -exec rm -f {} \;
	rm -rf build/deploy/build

# List all of the dependencies which are not part of the standard
# library or cockroachdb/cockroach.
godeps:
	@go list -f '{{range .Deps}}{{printf "%s\n" .}}{{end}}' ./... | \
	  sort | uniq | egrep '[^/]+\.[^/]+/' | \
	  egrep -v 'github.com/cockroachdb/cockroach'

.PHONY: build test testrace bench testbuild coverage acceptance clean gopath godeps depvers
