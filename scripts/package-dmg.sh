#!/bin/bash
# Packages an already exported app; archiving/exporting stays in Xcode.
# Creates and signs a DMG only. Notarization and stapling are separate release steps.
# Stop on failed commands, unset variables, and failures within pipelines.
set -euo pipefail
# Use Apple's system tools consistently, regardless of the caller's shell setup.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# make dmg passes the exported app path and Developer ID certificate name here.
# Empty defaults let us print a useful usage error when arguments are missing.
app=${1:-}
identity=${2:-}
[[ -n "$app" && -n "$identity" ]] || fail 'Usage: make dmg APP="/path/MacDevCleaner.app" SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"'
[[ -d "$app" && ! -L "$app" && "$app" == *.app ]] || fail 'APP must point to an exported .app bundle.'
[[ "$identity" == 'Developer ID Application: '* ]] || fail 'Use a Developer ID Application signing identity.'

# A certificate name is only a selector, not a credential. The matching certificate
# and private key must be available locally for codesign to sign the outer DMG.
# Check before creating the image, even if Xcode already signed the exported app.
identities=$(/usr/bin/security find-identity -v -p codesigning)
[[ "$identities" == *"\"$identity\""* ]] || fail "No valid local signing identity named '$identity'. Create or import a Developer ID Application certificate with its private key, then copy its exact name from: security find-identity -v -p codesigning"

# Confirm this is MacDevCleaner and read the version/build for the DMG filename.
# Restrict those values to digits and dots so they are safe filename components.
info="$app/Contents/Info.plist"
[[ -f "$info" ]] || fail 'The app has no Contents/Info.plist.'
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
[[ "$bundle_id" == com.kinn.MacDevCleaner ]] || fail 'Expected the com.kinn.MacDevCleaner app.'
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ && "$build" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail 'Version and build must contain only digits and dots.'

# Verify the app and any nested signed code before copying it into the image.
# A valid development signature is insufficient: direct releases need Developer ID,
# a secure signing timestamp, and Hardened Runtime for notarization.
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
signature=$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)
[[ "$signature" == *'Authority=Developer ID Application: '* ]] || fail 'Export the app with Developer ID Application signing in Xcode.'
[[ "$signature" == *'Timestamp='* ]] || fail 'The app needs a secure signing timestamp.'
[[ "$signature" == *'flags='*'(runtime)'* ]] || fail 'The app must have Hardened Runtime enabled.'

# Keep entitlement inspection, staging, and the unfinished image in a unique
# temporary directory. The EXIT trap removes it on success or ordinary failure.
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/MacDevCleaner-dmg.XXXXXX")
trap '/bin/rm -rf "$work"' EXIT
# Reject get-task-allow=true, which allows debugger attachment and is unsuitable
# for a release. No entitlements, or an absent get-task-allow key, is acceptable.
/usr/bin/codesign --display --entitlements - --xml "$app" > "$work/entitlements.plist"
if [[ -s "$work/entitlements.plist" ]]; then
    /usr/bin/plutil -lint "$work/entitlements.plist" >/dev/null
    debug=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$work/entitlements.plist" 2>/dev/null || true)
    [[ "$debug" != true ]] || fail 'The app has debugging entitlements. Export a Release archive from Xcode.'
fi

# Resolve the output relative to this script, so it always goes into repo/dist.
# Refuse existing files and symlinks to protect previously packaged releases.
root=$(cd "$(dirname "$0")/.." && pwd)
output="$root/dist/MacDevCleaner-$version-$build.dmg"
[[ ! -e "$output" && ! -L "$output" ]] || fail "Output already exists: $output. Move it aside or increment the build number."
/bin/mkdir -p "$root/dist" "$work/staging"
# ditto preserves the bundle's metadata and signature. The Applications symlink
# gives users a drag-and-drop installation destination inside the mounted DMG.
/usr/bin/ditto "$app" "$work/staging/MacDevCleaner.app"
/bin/ln -s /Applications "$work/staging/Applications"
# UDZO creates a compressed, read-only disk image from the staging folder.
/usr/bin/hdiutil create -volname MacDevCleaner -srcfolder "$work/staging" -format UDZO "$work/MacDevCleaner.dmg"
# Sign the outer image separately; leave the exported app's signature intact.
/usr/bin/codesign --sign "$identity" --timestamp "$work/MacDevCleaner.dmg"
/usr/bin/codesign --verify --strict --verbose=2 "$work/MacDevCleaner.dmg"
# Publish the image locally only after signing succeeds. mv -n also protects an
# output created after our earlier check; it can skip the move without an error,
# so check whether the temporary source still exists before reporting success.
/bin/mv -n "$work/MacDevCleaner.dmg" "$output"
[[ ! -e "$work/MacDevCleaner.dmg" ]] || fail 'Output appeared during packaging; refusing to replace it.'
printf '\nCreated: %s\nNext: notarize and staple this DMG before publishing (see docs/distribution.md).\n' "$output"
