# Magic Camera — the commands that are not in Xcode.
#
# Builds on this host take ten minutes or more: batch every edit and build ONCE,
# at the end. Run `verify-docs` before every commit — it needs neither Xcode nor
# the network, and CI runs the same script on every pull request.

PROJECT := MagicCamera.xcodeproj
SCHEME  := MagicCamera
# There is NO usable simulator on this host as of 2026-09-10: `xcrun simctl list
# runtimes` is empty. The `iPhone 17` device still exists but was created against
# the iOS 26.3 runtime and Xcode here is 26.2, so it reports "runtime profile not
# found" and every simulator destination fails before anything compiles. Worse,
# `actool` needs a simulator runtime too, so `build-device` fails as well:
# "No available simulator runtimes for platform iphonesimulator". Install one with
# `xcodebuild -downloadPlatform iOS` (needs ~10 GB free; this host had 11 GB) and
# both targets come back. Until then `compile-check` proves the code compiles.
# See docs/FMEA.md §A.
SIM     := platform=iOS Simulator,name=iPhone 17
DEST    ?= $(SIM)
# Private DerivedData for CLI builds, so they never share Xcode's module cache.
DD      ?= /tmp/mc-dd-r89

.PHONY: help generate build build-device compile-check test verify-docs check clean

help:
	@echo "make generate     regenerate the Xcode project from project.yml (after adding/removing files)"
	@echo "make build        build once, for the simulator destination"
	@echo "make build-device build for a device (arm64), private DerivedData — the one to trust here"
	@echo "make compile-check device build minus the asset catalogue — runs with no simulator runtime; not an app"
	@echo "make test         run the unit suite  (only when asked for it)"
	@echo "make verify-docs  policy index, FMEA targets, breadcrumb kinds, links, test citations"
	@echo "make check        verify-docs + compile-check"

generate:
	xcodegen generate

build:
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -quiet

# The build to trust on this host. Three different CLI failures here have been
# transient and none of them the code — a swift-frontend crash precompiling the
# UIKit PCM for the x86_64 simulator, a build-system crash on CompileMetalFile,
# and a Metal toolchain whose on-demand disk image was not yet attached. A
# device destination avoids the x86 simulator path entirely, and the private
# derivedDataPath keeps CLI builds out of Xcode's own module cache. Retry once
# before believing any failure. See docs/FMEA.md §A.
build-device:
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' -derivedDataPath $(DD) \
		CODE_SIGNING_ALLOWED=NO -quiet

# Every Swift and Metal source, compiled for a device with the asset catalogue
# excluded. `actool` is the only step that needs a simulator runtime, so this is
# the build that runs on a host without one (2026-09-11: first attempt died in a
# transient swift-frontend segfault, the retry was clean). It is a compile check,
# not an app — no icon, no accent colour — so never install the product. Safe
# because the code uses no generated asset symbols (Image(.name) / ColorResource).
compile-check:
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS' -derivedDataPath $(DD) \
		CODE_SIGNING_ALLOWED=NO EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets \
		ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO \
		ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS=NO -quiet

# Count failures with `grep "' failed ("` — XCTest's trailing tally counts
# ASSERTIONS, not tests, and reading it has invented a regression before.
test:
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' 2>&1 \
		| tee /tmp/magiccamera-test.log \
		| grep -E "^(Test Suite|Test Case).*(passed|failed)" || true
	@echo "--- failures ---"
	@grep "' failed (" /tmp/magiccamera-test.log || echo "none"

verify-docs:
	@python3 scripts/verify-docs.py

# compile-check rather than build-device: it runs on this host with or without a
# simulator runtime. build-device adds only the asset catalogue on top.
check: verify-docs compile-check

clean:
	xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) -quiet
