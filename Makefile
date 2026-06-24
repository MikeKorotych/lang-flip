APP_NAME := LangFlip
BUNDLE_NAME := LangFlip.app
BUILD_DIR := .build/release
APP_DIR := build/$(BUNDLE_NAME)
EXEC := $(BUILD_DIR)/$(APP_NAME)
# SPM-generated resource bundle — must sit next to the executable so
# Bundle.module can find it. The package name in Package.swift drives
# this filename; SPM produces "lang-flip_LangFlip.bundle" because the
# package is "lang-flip" and the target is "LangFlip".
RES_BUNDLE := $(BUILD_DIR)/lang-flip_LangFlip.bundle
# Sparkle ships as a binary xcframework via SPM. The framework's slice
# for the host arch ends up here after `swift build`. We copy the
# framework into Contents/Frameworks/ at app-bundle assembly time.
SPARKLE_FW := .build/arm64-apple-macosx/release/Sparkle.framework

# Read version from Info.plist so it's the single source of truth.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Resources/Info.plist)
DMG_NAME := LangFlip-$(VERSION).dmg
DMG_PATH := build/$(DMG_NAME)

# Codesigning identity. Override on the command line:
#   make sign DEVELOPER_ID="Developer ID Application: Foo (TEAMID)"
# Otherwise we autodetect the first Developer ID Application identity in
# the user's Keychain.
DEVELOPER_ID := $(shell security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

# Notarytool keychain profile — set up once with:
#   xcrun notarytool store-credentials lang-flip-notarize \
#       --apple-id you@example.com \
#       --team-id  TEAMID \
#       --password APP-SPECIFIC-PASSWORD
NOTARY_PROFILE := lang-flip-notarize

ENTITLEMENTS := Resources/lang-flip.entitlements

.PHONY: all build app clean run install dev dicts icon plan \
        reset-onboarding reset-onboarding-fresh reset-onboarding-empty \
        run-onboarding run-onboarding-empty \
        sign dmg notarize-app notarize-dmg staple staple-app release version \
        sign-update

all: app

# ─── Helpers ──────────────────────────────────────────────────────

version:
	@echo "$(VERSION)"

dicts:
	./Scripts/build-dicts.sh

# Regenerate AppIcon.iconset and AppIcon.icns from the master PNG
# at Resources/lang-flip-logo.png. Run after replacing the master.
icon:
	./Scripts/build-icon.sh

plan:
	@open docs/plan.html

# ─── Dev reset helpers ────────────────────────────────────────────

# Reset exactly the things that make the app feel like a first launch:
# app settings + macOS privacy permissions. Keeps downloaded models,
# runtimes, and dictionaries so repeated onboarding tests stay quick.
reset-onboarding:
	./Scripts/reset-onboarding.sh $(BUNDLE_ID) settings $(APP_NAME)

# Same reset, plus installed dictionaries and generated TTS files.
# This is the target for testing the onboarding checklist's dictionary
# install path. Heavy model/runtime downloads are deliberately kept.
reset-onboarding-fresh:
	./Scripts/reset-onboarding.sh $(BUNDLE_ID) fresh $(APP_NAME)

# Full new-user reset: settings + permissions + dictionaries + generated
# audio + downloaded LangFlip models/runtimes. Also removes qwen3.5:4b
# from Ollama if the Ollama CLI is available.
reset-onboarding-empty:
	./Scripts/reset-onboarding.sh $(BUNDLE_ID) empty $(APP_NAME)

# One command for a clean first-run pass: reset state, rebuild/install,
# and launch the signed /Applications copy.
run-onboarding: reset-onboarding-fresh
	$(MAKE) run

# Same as run-onboarding, but starts without downloaded local models.
# Use this to test whether a brand-new user can install/select models
# from the onboarding flow without hidden state on the machine.
run-onboarding-empty: reset-onboarding-empty
	$(MAKE) run

# ─── Build ────────────────────────────────────────────────────────

build:
	swift build -c release

app: build
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@mkdir -p $(APP_DIR)/Contents/Frameworks
	@cp $(EXEC) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	# Sparkle ships as a binary xcframework. Copy the macOS slice into
	# Contents/Frameworks and add the standard Apple-bundle rpath to the
	# executable so dyld can find it at @executable_path/../Frameworks.
	# (SPM-linked binaries default to @loader_path, which is MacOS/.)
	@if [ -d $(SPARKLE_FW) ]; then \
		cp -R $(SPARKLE_FW) $(APP_DIR)/Contents/Frameworks/; \
		install_name_tool -add_rpath "@executable_path/../Frameworks" \
			$(APP_DIR)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true; \
	fi
	# Copy bundled dictionaries straight into Resources/Dictionaries
	# rather than nesting them inside the SPM-generated
	# lang-flip_LangFlip.bundle. That sub-bundle has no Info.plist
	# (it's a plain data folder named with .bundle suffix), which
	# makes codesign refuse to sign the .app for distribution.
	# AutoFlip.loadResource looks here first, falls back to
	# Bundle.module for dev runs from .build/release.
	@if [ -d $(RES_BUNDLE)/Dictionaries ]; then \
		mkdir -p $(APP_DIR)/Contents/Resources/Dictionaries; \
		cp $(RES_BUNDLE)/Dictionaries/*.txt $(APP_DIR)/Contents/Resources/Dictionaries/; \
	fi
	@cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then \
		cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/AppIcon.icns; \
	fi
	@if [ -f Resources/scan-text-icon.png ]; then \
		cp Resources/scan-text-icon.png $(APP_DIR)/Contents/Resources/scan-text-icon.png; \
	fi
	@if [ -f Resources/search-icon.png ]; then \
		cp Resources/search-icon.png $(APP_DIR)/Contents/Resources/search-icon.png; \
	fi
	@codesign --force --deep --sign - $(APP_DIR) 2>/dev/null || true
	@echo "✓ Built $(APP_DIR)"

# For this app, running the build/ copy is actively misleading during
# development: macOS privacy permissions (Accessibility / Input
# Monitoring) are tied to the signed installed bundle, while build/
# gets ad-hoc-signed and can show stale or missing TCC state. Treat
# `make run` as the daily signed install + launch path.
run: dev

install: app
	@rm -rf /Applications/$(BUNDLE_NAME)
	@cp -R $(APP_DIR) /Applications/
	@echo "✓ Installed to /Applications/$(BUNDLE_NAME)"

# Daily dev cycle: sign with Developer ID (so TCC entries persist
# across rebuilds — adhoc-signed binaries get a new TCC identity on
# every change and ask for Accessibility/Input-Monitoring perms each
# time), install into /Applications, kill any running instance, open.
#
# This is the target you want for "I just made a code change, let me
# test it." `make run` aliases to this target too, because launching
# the build/ copy is a TCC footgun for a keyboard-monitoring app.
dev: sign
	@echo "→ Replacing /Applications/$(BUNDLE_NAME)…"
	@killall $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/$(BUNDLE_NAME)
	@cp -R $(APP_DIR) /Applications/
	@echo "✓ Installed Developer-ID-signed build to /Applications/$(BUNDLE_NAME)"
	@open /Applications/$(BUNDLE_NAME)
	@sleep 3
	# Smoke test: did the process survive past startup? Crashes in
	# applicationDidFinishLaunching die in <1 s, so a 3-second
	# liveness check is plenty. Surfacing the fact loud + pointing at
	# the freshly-written crash log saves users from chasing
	# "the app won't open" red herrings.
	@if ! pgrep -x $(APP_NAME) > /dev/null; then \
		echo ""; \
		echo "✗ FATAL: $(APP_NAME) crashed during startup."; \
		LATEST=$$(ls -t ~/Library/Logs/DiagnosticReports/$(APP_NAME)* 2>/dev/null | head -1); \
		if [ -n "$$LATEST" ]; then \
			echo "  Latest crash log: $$LATEST"; \
			echo "  Top of crashed thread:"; \
			python3 -c "import json,sys; \
				f=open('$$LATEST'); f.readline(); d=json.load(f); \
				[print('   ', fr.get('symbol','?')) for thr in d.get('threads',[]) if thr.get('triggered') for fr in thr.get('frames',[])[:8]]" 2>/dev/null || echo "  (could not parse log)"; \
		fi; \
		exit 1; \
	fi
	# Second `open` triggers applicationShouldHandleReopen, which our
	# AppDelegate uses to pop Preferences — visual confirmation that
	# the launch succeeded. Important for menubar-only apps where the
	# icon hides behind the notch on MacBooks.
	@open /Applications/$(BUNDLE_NAME)
	@echo "✓ Launched and alive. Preferences window should be visible."

# ─── Distribution: sign / dmg / notarize / release ────────────────

# Re-sign the .app with a Developer ID Application identity and the
# hardened runtime. Required for notarization.
sign: app
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "✗ No 'Developer ID Application' certificate found in Keychain."; \
		echo "  Get one at https://developer.apple.com/account/resources/certificates/add"; \
		echo "  (pick 'Developer ID Application'), then re-run make sign."; \
		exit 1; \
	fi
	@echo "→ Signing with: $(DEVELOPER_ID)"
	# Sparkle ships .framework with its XPC services already signed by the
	# Sparkle project (since 2.6). We only need to (re-)sign the framework
	# wrapper itself before signing the host app — codesign refuses to
	# embed an un-(re-)signed framework with our Developer ID.
	@if [ -d $(APP_DIR)/Contents/Frameworks/Sparkle.framework ]; then \
		codesign --force --options runtime --timestamp \
			--sign "$(DEVELOPER_ID)" \
			$(APP_DIR)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc 2>/dev/null || true; \
		codesign --force --options runtime --timestamp \
			--sign "$(DEVELOPER_ID)" \
			$(APP_DIR)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc 2>/dev/null || true; \
		codesign --force --options runtime --timestamp \
			--sign "$(DEVELOPER_ID)" \
			$(APP_DIR)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate; \
		codesign --force --options runtime --timestamp \
			--sign "$(DEVELOPER_ID)" \
			$(APP_DIR)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app; \
		codesign --force --options runtime --timestamp \
			--sign "$(DEVELOPER_ID)" \
			$(APP_DIR)/Contents/Frameworks/Sparkle.framework; \
	fi
	@codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(DEVELOPER_ID)" \
		$(APP_DIR)
	@codesign --verify --strict --verbose=2 $(APP_DIR) 2>&1 | tail -3
	@echo "✓ Signed $(APP_DIR)"

# Build a drag-to-Applications DMG from whatever .app is currently in
# build/. Deliberately NOT a target dep on `app` — the release pipeline
# (sign → dmg → notarize) needs the Developer-ID-signed .app to survive
# into the DMG, but `make app` ad-hoc-resigns the bundle and would
# clobber the Developer ID signature.
#
# Standalone unsigned use: `make app dmg` (two targets).
# Signed release use:       `make release` (sign first, then dmg).
dmg:
	@if [ ! -d $(APP_DIR) ]; then \
		echo "✗ $(APP_DIR) does not exist. Run \`make app\` (unsigned) or \`make sign\` (signed) first."; \
		exit 1; \
	fi
	@rm -f $(DMG_PATH)
	@create-dmg \
		--volname "LangFlip" \
		--window-size 500 320 \
		--icon-size 96 \
		--icon "$(BUNDLE_NAME)" 130 150 \
		--app-drop-link 370 150 \
		--no-internet-enable \
		"$(DMG_PATH)" \
		"$(APP_DIR)" \
		>/dev/null
	@echo "✓ $(DMG_PATH) ($$(du -h $(DMG_PATH) | awk '{print $$1}'))"

# Notarize the .app and embed the ticket directly into the bundle.
# Stapling the .app (rather than only the DMG) means the ticket
# travels with it: drag from DMG to /Applications offline and the
# first launch still works without an internet round-trip.
notarize-app: sign
	@echo "→ Zipping $(APP_DIR) for notarytool…"
	@ditto -c -k --keepParent $(APP_DIR) build/$(APP_NAME)-notarize.zip
	@echo "→ Submitting to Apple notarytool (1–15 min)…"
	@xcrun notarytool submit build/$(APP_NAME)-notarize.zip \
		--keychain-profile $(NOTARY_PROFILE) \
		--wait
	@rm -f build/$(APP_NAME)-notarize.zip
	@echo "→ Stapling ticket onto $(APP_DIR)…"
	@xcrun stapler staple $(APP_DIR)
	@xcrun stapler validate $(APP_DIR)
	@echo "✓ Notarized: $(APP_DIR)"

# Legacy alias kept for muscle memory: submits the DMG instead and
# staples the DMG. End users dragging the .app *out* of the DMG won't
# get a stapled .app this way — prefer notarize-app.
notarize-dmg: dmg
	@echo "→ Submitting $(DMG_PATH) to Apple notarytool…"
	@xcrun notarytool submit $(DMG_PATH) \
		--keychain-profile $(NOTARY_PROFILE) \
		--wait
	@xcrun stapler staple $(DMG_PATH)
	@xcrun stapler validate $(DMG_PATH)
	@echo "✓ Notarized: $(DMG_PATH)"

# Re-run if `make release` was interrupted while Apple was still processing
# the notarization. Stapler can fetch the ticket from Apple any time after
# notarization completes, even days later.
# Print the sparkle:edSignature and length attributes for an existing
# DMG so they can be pasted into docs/appcast.xml. Uses the EdDSA
# private key in your login.keychain (created once with Sparkle's
# generate_keys, paired with SUPublicEDKey in Info.plist).
sign-update:
	@if [ -z "$(DMG)" ]; then \
		echo "Usage: make sign-update DMG=build/LangFlip-X.Y.Z.dmg"; \
		exit 2; \
	fi
	./Scripts/sign-update.sh $(DMG)

staple:
	@xcrun stapler staple $(DMG_PATH)
	@xcrun stapler validate $(DMG_PATH)
	@echo "✓ Stapled: $(DMG_PATH)"

# Useful for re-stapling the .app after a cached notarization succeeds, or
# for verifying things end-to-end without rebuilding.
staple-app: app
	@xcrun stapler staple $(APP_DIR)
	@xcrun stapler validate $(APP_DIR)
	@echo "✓ Stapled: $(APP_DIR)"

# One-shot: sign .app → notarize + staple .app → wrap into DMG.
# The resulting DMG contains a stapled .app (offline first launch
# works) and is fit to publish on GitHub Releases.
release: notarize-app dmg
	@echo
	@echo "✓ Release artifact ready: $(DMG_PATH)"
	@echo "  Next: gh release create v$(VERSION) $(DMG_PATH)"

clean:
	@rm -rf .build build
	@echo "✓ Cleaned"
