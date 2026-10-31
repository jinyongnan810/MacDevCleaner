.PHONY: lint dmg

lint:
	swiftformat . --exclude Pods,Generated

# APP must be an app exported from Xcode for Developer ID distribution.
dmg:
	@/bin/bash scripts/package-dmg.sh "$(APP)" "$(SIGN_IDENTITY)"
