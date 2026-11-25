SHELL := /bin/bash

APP_NAME := MachineKeeper
BUNDLE := dist/$(APP_NAME).app
BINARY := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
VERSION := $(shell node -p "require('./package.json').version" 2>/dev/null || echo 0.0.0)

.PHONY: test app app-run app-test app-clean

test:
	node --test test/

# SwiftPM builds the executable; the bundle is assembled by hand because this
# machine has CommandLineTools only (no xcodebuild). Unsigned local build.
app:
	@test "$$(uname -s)" = Darwin || { echo "the menu-bar app builds only on macOS"; exit 1; }
	swift build -c release --package-path app
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp app/.build/release/mkbar "$(BINARY)"
	cp app/Info.plist "$(BUNDLE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(BUNDLE)/Contents/Info.plist"
	plutil -lint "$(BUNDLE)/Contents/Info.plist"
	@if command -v codesign >/dev/null 2>&1; then \
		codesign --force --sign - "$(BUNDLE)"; \
	else \
		echo "codesign unavailable; leaving the bundle unsigned"; \
	fi
	@echo "Built $(BUNDLE)"

# Launch the bundle's binary directly so MK_BIN from this shell is inherited.
# A Finder-launched app gets launchd's minimal environment instead.
app-run: app
	@echo "Launching $(BUNDLE) — Ctrl-C to quit"
	@MK_BIN="$(MK_BIN)" "$(BINARY)"

app-test:
	swift test --package-path app

app-clean:
	rm -rf dist app/.build
	@echo "Removed dist/ and app/.build"
