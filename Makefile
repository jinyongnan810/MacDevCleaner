.PHONY: lint dmg package release

lint:
	swiftformat . --exclude Pods,Generated

# Automated full packaging pipeline: build, export, DMG creation, notarization, and stapling.
# Options can be passed via ARGS, e.g.: make package ARGS="--force"
package:
	@/bin/bash scripts/package.sh $(ARGS)

# Automated packaging + GitHub release creation & asset upload via gh CLI.
# Usage: make release [ARGS="--force"]
release:
	@/bin/bash scripts/package.sh --release $(ARGS)

# APP must be an app exported from Xcode for Developer ID distribution.
dmg:
	@/bin/bash scripts/package-dmg.sh "$(APP)" "$(SIGN_IDENTITY)"
