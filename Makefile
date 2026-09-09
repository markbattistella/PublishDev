PREFIX ?= /usr/local

.PHONY: build test format lint install uninstall

build:
	swift build -c release

test:
	swift test

format:
	swift format --in-place --recursive Package.swift Sources Tests

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

# Prints exactly what it will change outside the project, then asks before doing it.
install:
	@PREFIX=$(PREFIX) Scripts/install.sh

uninstall:
	@PREFIX=$(PREFIX) Scripts/uninstall.sh
