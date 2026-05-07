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

# Read version from Info.plist so it's the single source of truth.
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
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

.PHONY: all build app clean run install dicts icon \
        sign dmg notarize staple release version

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

# ─── Build ────────────────────────────────────────────────────────

build:
	swift build -c release

app: build
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(EXEC) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
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
	@codesign --force --deep --sign - $(APP_DIR) 2>/dev/null || true
	@echo "✓ Built $(APP_DIR)"

run: app
	@open $(APP_DIR)

install: app
	@rm -rf /Applications/$(BUNDLE_NAME)
	@cp -R $(APP_DIR) /Applications/
	@echo "✓ Installed to /Applications/$(BUNDLE_NAME)"

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
	@codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) \
		--sign "$(DEVELOPER_ID)" \
		$(APP_DIR)
	@codesign --verify --deep --strict --verbose=2 $(APP_DIR) 2>&1 | tail -3
	@echo "✓ Signed $(APP_DIR)"

# Build a drag-to-Applications DMG. Works without a Developer ID, but
# the .app inside should already be signed for an end user not to see
# Gatekeeper warnings.
dmg: app
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

# Submit the DMG to Apple for notarization, wait for the result, then
# staple the ticket so end users don't need internet on first launch.
notarize: dmg
	@echo "→ Submitting $(DMG_PATH) to Apple notarytool…"
	@xcrun notarytool submit $(DMG_PATH) \
		--keychain-profile $(NOTARY_PROFILE) \
		--wait
	@echo "→ Stapling ticket to $(DMG_PATH)…"
	@xcrun stapler staple $(DMG_PATH)
	@xcrun stapler validate $(DMG_PATH)
	@echo "✓ Notarized: $(DMG_PATH)"

# Re-run if `make release` was interrupted while Apple was still processing
# the notarization. Stapler can fetch the ticket from Apple any time after
# notarization completes, even days later.
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

# One-shot: build → sign .app → make DMG → notarize → staple. The
# resulting DMG is fit to publish on GitHub Releases.
release: sign dmg notarize
	@echo
	@echo "✓ Release artifact ready: $(DMG_PATH)"
	@echo "  Next: gh release create v$(VERSION) $(DMG_PATH)"

clean:
	@rm -rf .build build
	@echo "✓ Cleaned"
