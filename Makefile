PREFIX ?= /usr/local

.PHONY: build test test-session format lint install uninstall

build:
	swift build -c release

test:
	swift test

test-session:
	swift build
	python3 Scripts/test-session.py "$$(swift build --show-bin-path)/publish-dev"

format:
	swift format --in-place --recursive Package.swift Sources Tests

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

# Prints exactly what it will change outside the project, then asks before doing it.
install:
	@PREFIX=$(PREFIX) Scripts/install.sh

uninstall:
	@PREFIX=$(PREFIX) Scripts/uninstall.sh
