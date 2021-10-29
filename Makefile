export SHELL:=/bin/bash
export SHELLOPTS:=$(if $(SHELLOPTS),$(SHELLOPTS):)pipefail:errexit

CWD=$(shell pwd)

.PHONY: all build

all: build

build:
	./build

