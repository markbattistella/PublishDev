PREFIX ?= /usr/local
export VERSION

.PHONY: build test test-session test-release release prepare-release release-version check-release format lint install uninstall

build:
	swift build -c release

test:
	swift test

test-session:
	swift build
	python3 Scripts/test-session.py "$$(swift build --show-bin-path)/publish-dev"

test-release:
	python3 -B -m unittest discover -s Tests/ReleaseToolTests -p 'test_*.py'

# Commit the version and push the branch and tag; GitHub validates and publishes.
release:
	python3 Scripts/release.py release "$$VERSION"

# Optional edit-only step. `make release` includes this automatically.
prepare-release release-version:
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
