APP_NAME := LangFlip
BUNDLE_NAME := lang-flip.app
BUILD_DIR := .build/release
APP_DIR := build/$(BUNDLE_NAME)
EXEC := $(BUILD_DIR)/$(APP_NAME)
# SPM-generated resource bundle — must sit next to the executable so
# Bundle.module can find it.
RES_BUNDLE := $(BUILD_DIR)/lang-flip_LangFlip.bundle

.PHONY: all build app clean run install dicts icon

all: app

dicts:
	./Scripts/build-dicts.sh

# Regenerate AppIcon.iconset and AppIcon.icns from the master PNG
# at Resources/lang-flip-logo.png. Run after replacing the master.
icon:
	./Scripts/build-icon.sh

build:
	swift build -c release

app: build
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(EXEC) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	@if [ -d $(RES_BUNDLE) ]; then \
		cp -R $(RES_BUNDLE) $(APP_DIR)/Contents/MacOS/; \
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

clean:
	@rm -rf .build build
	@echo "✓ Cleaned"
