.PHONY: lint dmg package

lint:
	swiftformat . --exclude Pods,Generated

# Automated full packaging pipeline: build, export, DMG creation, notarization, and stapling.
# Options can be passed via ARGS, e.g.: make package ARGS="--force"
package:
	@/bin/bash scripts/package.sh $(ARGS)

# APP must be an app exported from Xcode for Developer ID distribution.
dmg:
	@/bin/bash scripts/package-dmg.sh "$(APP)" "$(SIGN_IDENTITY)"
