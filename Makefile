SHELL := /bin/bash

APP_NAME := MachineKeeper
BUNDLE := dist/$(APP_NAME).app
STAGED := dist/.$(APP_NAME).staged.app
BINARY := $(STAGED)/Contents/MacOS/$(APP_NAME)
RUN_BINARY := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
CLI_DIR := $(STAGED)/Contents/Resources/cli
VERSION := $(shell node -p "require('./package.json').version" 2>/dev/null || echo 0.0.0)

.PHONY: test app app-run app-test app-clean

test:
	node --test test/*.test.mjs

# SwiftPM builds the executable; the bundle is assembled by hand because this
# machine has CommandLineTools only (no xcodebuild). The bundle is staged and
# swapped in only after signing, so a failed build leaves the previous app
# intact. Unsigned local builds fall back to an unsigned bundle.
app:
	@test "$$(uname -s)" = Darwin || { echo "the menu-bar app builds only on macOS"; exit 1; }
	swift build -c release --package-path app
	rm -rf "$(STAGED)"
	mkdir -p "$(STAGED)/Contents/MacOS" "$(STAGED)/Contents/Resources" "$(CLI_DIR)"
	cp app/.build/release/mkbar "$(BINARY)"
	cp app/Info.plist "$(STAGED)/Contents/Info.plist"
	cp policy.json "$(STAGED)/Contents/Resources/policy.json"
	cp -R bin src rules.default.json package.json LICENSE "$(CLI_DIR)/"
	cp policy.json "$(CLI_DIR)/"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(STAGED)/Contents/Info.plist"
	plutil -lint "$(STAGED)/Contents/Info.plist"
	@if command -v codesign >/dev/null 2>&1; then \
		codesign --force --sign - "$(STAGED)"; \
	else \
		echo "codesign unavailable; leaving the bundle unsigned"; \
	fi
	rm -rf "$(BUNDLE)"
	mv "$(STAGED)" "$(BUNDLE)"
	@echo "Built $(BUNDLE)"

# Launch the bundle's binary directly so MK_BIN from this shell is inherited.
# A Finder-launched app gets launchd's minimal environment instead.
app-run: app
	@echo "Launching $(BUNDLE) — Ctrl-C to quit"
	@MK_BIN="$(MK_BIN)" "$(RUN_BINARY)"

app-test:
	swift test --package-path app

app-clean:
	rm -rf dist app/.build
	@echo "Removed dist/ and app/.build"
