export SHELL:=/bin/bash
export SHELLOPTS:=$(if $(SHELLOPTS),$(SHELLOPTS):)pipefail:errexit

CWD=$(shell pwd)

export VERSION?

.PHONY: all build

all: build

build:
	./build $(VERSION)

