APP_NAME := LangFlip
BUNDLE_NAME := lang-flip.app
BUILD_DIR := .build/release
APP_DIR := build/$(BUNDLE_NAME)
EXEC := $(BUILD_DIR)/$(APP_NAME)

.PHONY: all build app clean run install

all: app

build:
	swift build -c release

app: build
	@rm -rf $(APP_DIR)
	@mkdir -p $(APP_DIR)/Contents/MacOS
	@mkdir -p $(APP_DIR)/Contents/Resources
	@cp $(EXEC) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
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
