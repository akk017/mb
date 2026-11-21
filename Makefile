# MiniBrain build entry points.
#
# With full Xcode installed, `make test` runs `xcodebuild test` on the package.
# With only the Command Line Tools, it falls back to `swift test` plus a small
# workaround for stale files some CLT installs ship (see
# scripts/clt-workaround.sh). The workaround lives in .build-tools/, no sudo.

CLT        := /Library/Developer/CommandLineTools
TOOLS      := $(CURDIR)/.build-tools
HAS_XCODE  := $(shell xcodebuild -version >/dev/null 2>&1 && echo 1)
CONFIG     ?= debug

ifeq ($(HAS_XCODE),1)
SWIFT_ENV   :=
SWIFT_FLAGS :=
PREREQ      :=
else
TESTING_FW  := $(CLT)/Library/Developer/Frameworks
SWIFT_ENV   := SWIFTPM_CUSTOM_LIBS_DIR=$(TOOLS)/pm SWIFT_EXEC_MANIFEST=$(TOOLS)/swiftc-manifest MB_NO_KEYBOARDSHORTCUTS=1
SWIFT_FLAGS := -Xswiftc -vfsoverlay -Xswiftc $(TOOLS)/overlay.yaml \
               -Xcc -ivfsoverlay -Xcc $(TOOLS)/overlay.yaml \
               -Xswiftc -F -Xswiftc $(TESTING_FW) \
               -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
               -Xlinker -F -Xlinker $(TESTING_FW) \
               -Xlinker -rpath -Xlinker $(TESTING_FW)
PREREQ      := $(TOOLS)/.ready
endif

ifeq ($(CONFIG),release)
SPM_CONFIG   := -c release -Xswiftc -enable-testing
XCODE_CONFIG := Release
else
SPM_CONFIG   :=
XCODE_CONFIG := Debug
endif

.PHONY: test test-release build release app dmg install fixtures

test: $(PREREQ)
ifeq ($(HAS_XCODE),1)
	xcodebuild test -scheme MiniBrain-Package -destination 'platform=macOS' -configuration $(XCODE_CONFIG)
else
	$(SWIFT_ENV) swift test $(SPM_CONFIG) $(SWIFT_FLAGS)
endif

test-release:
	$(MAKE) test CONFIG=release

build: $(PREREQ)
	$(SWIFT_ENV) swift build $(SWIFT_FLAGS)

release: $(PREREQ)
	$(SWIFT_ENV) swift build -c release $(SWIFT_FLAGS) --product MiniBrain

app: release
	./scripts/make-app.sh "$$($(SWIFT_ENV) swift build -c release $(SWIFT_FLAGS) --show-bin-path)"

dmg: app
	./scripts/make-dmg.sh

# Copies the fresh build to /Applications, ejects old MiniBrain disk images,
# and relaunches it.
install: app
	./scripts/install.sh

fixtures: $(PREREQ)
	$(SWIFT_ENV) swift run $(SWIFT_FLAGS) mbtool make-fixtures Tests/Fixtures

$(TOOLS)/.ready: scripts/clt-workaround.sh
	./scripts/clt-workaround.sh $(TOOLS)
	@touch $@
