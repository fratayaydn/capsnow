# CapsNow: `make` builds .build/CapsNow.app (hidden, so Spotlight does not list the build copy), `make install` copies it to /Applications and opens it.
# `make dmg` builds the disk image; `make release` builds, notarizes and staples it (Developer ID required).
VERSION  := 1.0.1
BUILD    ?= .build
APP      := $(BUILD)/CapsNow.app
STAGE    := $(BUILD)/stage/CapsNow.app
CONTENTS := $(STAGE)/Contents
AGENT_ID := io.github.fratayaydn.capsnow.agent
MIN_OS   := 13.0
ARCH     := $(shell uname -m)
CFLAGS   := -O2 -fobjc-arc -Wall -mmacosx-version-min=$(MIN_OS)
DIAGNOSTIC_LOG ?= 0
ifeq ($(DIAGNOSTIC_LOG),1)
AGENT_DIAGNOSTIC_FLAGS := -DCAPSNOW_DIAGNOSTIC_LOG
endif

# Code signing identity. The default is a self-signed certificate created once per Mac by
# scripts/create-signing-identity.sh: a fixed signature keeps the login item working across rebuilds (an ad-hoc
# signature changes with every build). For distribution use Developer ID:
#   make SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
SIGN_IDENTITY ?= Local Code Signing
TIMESTAMP     ?=
SIGN_FLAGS    := --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)"

# Release builds go to their own folder, signed with Developer ID and a secure timestamp (notarization needs both).
# Set RELEASE_IDENTITY and NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile) on the command line or
# in release.local.mk, which is not committed:
#   RELEASE_IDENTITY := Developer ID Application: Your Name (TEAMID)
#   NOTARY_PROFILE   := my-notary-profile
-include release.local.mk
RELEASE_DIR      := .build/release
RELEASE_IDENTITY ?=
NOTARY_PROFILE   ?= notary
DMG              := $(RELEASE_DIR)/CapsNow-$(VERSION).dmg

AGENT_SRC := Sources/Agent/capsnowd.m
AGENT_HEADERS := Sources/Agent/DiagnosticLog.h
APP_SRC   := Sources/App/CapsNowApp.swift Sources/App/Updates.swift
UPDATER_SRC := Sources/Updater/Updater.m
UPDATER_HEADERS := Sources/Updater/Updater.h

.PHONY: all clean install uninstall signing-identity release-app dmg release test check-logging diagnostic FORCE

all: $(APP)

# Local troubleshooting build with an in-memory diagnostic log.
diagnostic:
	$(MAKE) DIAGNOSTIC_LOG=1 all

FORCE:

$(BUILD)/agent-build-mode: FORCE
	@mkdir -p $(BUILD)
	@if [ ! -f $@ ] || [ "$$(cat $@)" != "$(DIAGNOSTIC_LOG)" ]; then echo "$(DIAGNOSTIC_LOG)" > $@; fi

signing-identity:
	@if [ "$(SIGN_IDENTITY)" = "Local Code Signing" ]; then ./scripts/create-signing-identity.sh "$(SIGN_IDENTITY)"; fi

# signing-identity is order-only (after |): it must exist, but checking for it must not force a rebuild.
$(APP): $(AGENT_SRC) $(AGENT_HEADERS) $(APP_SRC) $(UPDATER_SRC) $(UPDATER_HEADERS) Sources/Updater/main.m Resources/Info.plist Resources/$(AGENT_ID).plist $(wildcard Resources/AppIcon.icns) $(BUILD)/agent-build-mode Makefile | signing-identity
	rm -rf $(STAGE)
	mkdir -p $(BUILD)/module-cache $(CONTENTS)/MacOS $(CONTENTS)/Resources $(CONTENTS)/Library/LaunchAgents
	clang $(CFLAGS) $(AGENT_DIAGNOSTIC_FLAGS) -framework Foundation -framework IOKit $(AGENT_SRC) -o $(CONTENTS)/MacOS/capsnowd
	clang $(CFLAGS) -framework Foundation -framework Security $(UPDATER_SRC) Sources/Updater/main.m -o $(CONTENTS)/MacOS/capsnow-update
	swiftc -O -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library -target $(ARCH)-apple-macos$(MIN_OS) \
		$(APP_SRC) -o $(CONTENTS)/MacOS/CapsNow
	sed -e 's/VERSION/$(VERSION)/' -e "s/BUILD_ID/$$(date +%Y%m%d%H%M%S)/" Resources/Info.plist > $(CONTENTS)/Info.plist
	cp Resources/$(AGENT_ID).plist $(CONTENTS)/Library/LaunchAgents/
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(CONTENTS)/Resources/; fi
	codesign $(SIGN_FLAGS) --identifier $(AGENT_ID) $(CONTENTS)/MacOS/capsnowd
	codesign $(SIGN_FLAGS) --identifier io.github.fratayaydn.capsnow.update $(CONTENTS)/MacOS/capsnow-update
	codesign $(SIGN_FLAGS) $(STAGE)
	rm -rf $(APP)
	mv $(STAGE) $(APP)

# scripts/install.sh replaces the app and keeps the background agent working across updates.
install: $(APP)
	./scripts/install.sh $(APP)

release-app:
	@if [ "$(DIAGNOSTIC_LOG)" != "0" ]; then echo "Release builds require DIAGNOSTIC_LOG=0."; exit 1; fi
	@if [ -z "$(RELEASE_IDENTITY)" ]; then echo "Set RELEASE_IDENTITY (see the Makefile)."; exit 1; fi
	rm -rf $(RELEASE_DIR)
	$(MAKE) BUILD=$(RELEASE_DIR) SIGN_IDENTITY="$(RELEASE_IDENTITY)" TIMESTAMP=--timestamp DIAGNOSTIC_LOG=0 AGENT_DIAGNOSTIC_FLAGS= all check-logging

# Disk image only, without notarization: for checking the window layout.
dmg: release-app
	./scripts/make-dmg.sh $(RELEASE_DIR)/CapsNow.app $(DMG) "$(RELEASE_IDENTITY)"

release: release-app
	./scripts/release.sh $(RELEASE_DIR)/CapsNow.app $(DMG) "$(RELEASE_IDENTITY)" $(NOTARY_PROFILE)

test: $(BUILD)/diagnostic-tests $(BUILD)/release-tests $(BUILD)/updater-tests $(BUILD)/updater-tools-tests $(BUILD)/updater-flow-tests $(BUILD)/update-window-tests
	$(BUILD)/diagnostic-tests
	$(BUILD)/release-tests
	$(BUILD)/updater-tests
	$(BUILD)/updater-tools-tests
	$(BUILD)/updater-flow-tests
	$(BUILD)/update-window-tests
	$(MAKE) BUILD=$(BUILD)/test-release SIGN_IDENTITY=- TIMESTAMP= DIAGNOSTIC_LOG=0 AGENT_DIAGNOSTIC_FLAGS= all check-logging

check-logging: $(APP)
	@set -e; for executable in $(APP)/Contents/MacOS/*; do \
		symbols=$$(nm -u "$$executable"); \
		if printf '%s\n' "$$symbols" | grep -E '(^|[[:space:]])_+(os_log[[:alnum:]_]*|NSLog[[:alnum:]_]*)([[:space:]]|$$)'; then \
			echo "FAIL: logging symbols in $$executable"; \
			exit 1; \
		fi; \
		echo "PASS: no logging symbols in $$executable"; \
	done

$(BUILD)/diagnostic-tests: $(AGENT_SRC) $(AGENT_HEADERS) Tests/diagnostic.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -DCAPSNOW_DIAGNOSTIC_LOG -framework Foundation -framework IOKit Tests/diagnostic.m -o $@

$(BUILD)/release-tests: $(AGENT_SRC) $(AGENT_HEADERS) Tests/diagnostic.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework IOKit Tests/diagnostic.m -o $@

$(BUILD)/updater-tests: $(UPDATER_SRC) $(UPDATER_HEADERS) Tests/updater.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework Security $(UPDATER_SRC) Tests/updater.m -o $@

$(BUILD)/updater-tools-tests: $(UPDATER_SRC) $(UPDATER_HEADERS) Tests/updater-tools.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework Security Tests/updater-tools.m -o $@

$(BUILD)/updater-flow-tests: $(UPDATER_SRC) $(UPDATER_HEADERS) Sources/Updater/main.m Tests/updater-flow.m
	mkdir -p $(BUILD)
	clang $(CFLAGS) -framework Foundation -framework Security Tests/updater-flow.m -o $@

$(BUILD)/update-window-tests: Sources/App/Updates.swift Tests/update-window.swift
	mkdir -p $(BUILD)/module-cache
	swiftc -module-cache-path $(BUILD)/module-cache -swift-version 5 -parse-as-library Sources/App/Updates.swift Tests/update-window.swift -o $@

uninstall:
	-pkill -x CapsNow
	-/Applications/CapsNow.app/Contents/MacOS/CapsNow --unregister
	-launchctl bootout gui/$$(id -u)/$(AGENT_ID) 2>/dev/null
	rm -rf /Applications/CapsNow.app
	defaults delete io.github.fratayaydn.capsnow 2>/dev/null || true
	@echo "CapsNow removed; the Caps Lock delay is back to the macOS default."

clean:
	rm -rf .build
