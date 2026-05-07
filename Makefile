APP_NAME := AulaF75Bar
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
PROBE := $(BUILD_DIR)/F75Probe
BAR_BIN := $(APP_DIR)/Contents/MacOS/$(APP_NAME)
APP_ICON := Resources/AulaF75Bar.icns

.PHONY: all clean app probe

all: probe app

probe: $(PROBE)

app: $(BAR_BIN) $(APP_DIR)/Contents/MacOS/F75Probe $(APP_DIR)/Contents/Info.plist $(APP_DIR)/Contents/Resources/AulaF75Bar.icns
	codesign --force --deep --sign - $(APP_DIR)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(PROBE): Sources/F75Probe/main.m | $(BUILD_DIR)
	clang -fobjc-arc -Wall -Wextra -framework CoreGraphics -framework Foundation -framework ImageIO -framework IOKit -o $@ $<

$(BAR_BIN): Sources/AulaF75Bar/main.m | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS
	clang -fobjc-arc -Wall -Wextra -framework AppKit -framework Foundation -framework ImageIO -framework IOKit -framework ServiceManagement -framework UniformTypeIdentifiers -o $@ $<

$(APP_DIR)/Contents/MacOS/F75Probe: $(PROBE) | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS
	cp $(PROBE) $@

$(APP_DIR)/Contents/Info.plist: Info.plist | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents
	cp Info.plist $@

$(APP_ICON): tools/make_app_icon.py
	python3 tools/make_app_icon.py

$(APP_DIR)/Contents/Resources/AulaF75Bar.icns: $(APP_ICON) | $(BUILD_DIR)
	mkdir -p $(APP_DIR)/Contents/Resources
	cp $(APP_ICON) $@

clean:
	rm -rf $(BUILD_DIR)
