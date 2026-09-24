PREFIX ?= /usr/local
export VERSION

.PHONY: build test test-session test-release prepare-release check-release format lint install uninstall

build:
	swift build -c release

test:
	swift test

test-session:
	swift build
	python3 Scripts/test-session.py "$$(swift build --show-bin-path)/publish-dev"

test-release:
	python3 -B -m unittest discover -s Tests/ReleaseToolTests -p 'test_*.py'

# Example: make prepare-release VERSION=0.1.2
prepare-release:
	python3 Scripts/release.py prepare "$$VERSION"

check-release:
	python3 Scripts/release.py check "$$VERSION"

format:
	swift format --in-place --recursive Package.swift Sources Tests

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

# Prints exactly what it will change outside the project, then asks before doing it.
install:
	@PREFIX=$(PREFIX) Scripts/install.sh

uninstall:
	@PREFIX=$(PREFIX) Scripts/uninstall.sh
