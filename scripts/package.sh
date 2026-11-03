#!/bin/bash
# Fully automated packaging script for MacDevCleaner.
# Builds the Release scheme, exports Developer ID application,
# creates and signs the DMG, notarizes with Apple Notary Service,
# staples the ticket, validates Gatekeeper compliance, generates sha256,
# and optionally creates a GitHub Release and uploads assets via gh CLI.
set -euo pipefail

# Use standard tool paths consistently
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin

fail() { printf '\n\033[1;31mError:\033[0m %b\n' "$*" >&2; exit 1; }
info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

root=$(cd "$(dirname "$0")/.." && pwd)

# Defaults from user configuration & environment variables
key_path="${MACDEV_P8_PATH:-/Users/kin/Documents/MacDevCleaner.p8}"
key_id="${MACDEV_KEY_ID:-Z962439KCL}"
issuer_id="${MACDEV_ISSUER_ID:-86621a93-af27-4c2a-9740-e91edb76fc3f}"
sign_identity="${MACDEV_SIGN_IDENTITY:-Developer ID Application: JIN YONGNAN (6W8B6G9KYD)}"
team_id="${MACDEV_TEAM_ID:-6W8B6G9KYD}"
force="${FORCE:-0}"
skip_notarize=0

# GitHub Release options
create_release="${MACDEV_GH_RELEASE:-0}"
release_tag=""
release_title=""
release_notes=""
release_notes_file=""
is_draft=0
is_prerelease=0
release_url=""

usage() {
    cat << 'EOF'
Usage: scripts/package.sh [options]

Automated packaging, signing, notarization, and stapling for MacDevCleaner.

Options:
  -k, --key-path <path>       Path to App Store Connect API .p8 private key
                              (default: /Users/kin/Documents/MacDevCleaner.p8)
  -d, --key-id <id>           App Store Connect API Key ID
                              (default: Z962439KCL)
  -i, --issuer-id <uuid>      App Store Connect API Issuer ID
                              (default: 86621a93-af27-4c2a-9740-e91edb76fc3f)
  -s, --sign-identity <name>  Developer ID Application identity
                              (default: Developer ID Application: JIN YONGNAN (6W8B6G9KYD))
  -t, --team-id <id>          Developer Team ID
                              (default: 6W8B6G9KYD)
  -f, --force                 Overwrite existing output in dist/ (or update existing GitHub release)
  --skip-notarize             Build and package signed DMG without notarization
  -r, --release               Create GitHub release & upload DMG + checksum via gh CLI
  --tag <tag>                 GitHub release tag (default: version from project, e.g. 1.0.2)
  --title <title>             GitHub release title (default: version)
  --notes <text>              Custom GitHub release notes
  --notes-file <file>         Read GitHub release notes from file
  --draft                     Create GitHub release as draft
  --prerelease                Mark GitHub release as prerelease
  -h, --help                  Show this help message

Environment variables (optional overrides):
  MACDEV_P8_PATH, MACDEV_KEY_ID, MACDEV_ISSUER_ID, MACDEV_SIGN_IDENTITY, MACDEV_TEAM_ID,
  MACDEV_GH_RELEASE, FORCE
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--key-path)
            key_path="$2"
            shift 2
            ;;
        -d|--key-id)
            key_id="$2"
            shift 2
            ;;
        -i|--issuer-id)
            issuer_id="$2"
            shift 2
            ;;
        -s|--sign-identity)
            sign_identity="$2"
            shift 2
            ;;
        -t|--team-id)
            team_id="$2"
            shift 2
            ;;
        -f|--force)
            force=1
            shift
            ;;
        --skip-notarize)
            skip_notarize=1
            shift
            ;;
        -r|--release|--gh-release)
            create_release=1
            shift
            ;;
        --tag)
            release_tag="$2"
            shift 2
            ;;
        --title)
            release_title="$2"
            shift 2
            ;;
        --notes)
            release_notes="$2"
            shift 2
            ;;
        --notes-file)
            release_notes_file="$2"
            shift 2
            ;;
        --draft)
            is_draft=1
            shift
            ;;
        --prerelease)
            is_prerelease=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            fail "Unknown option: $1 (run with -h for usage)"
            ;;
    esac
done

# 1. Check required tools
info "Verifying required tools..."
for tool in xcodebuild xcrun codesign hdiutil security spctl shasum plutil; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool '$tool' is not available in PATH."
done

if [[ "$create_release" -eq 1 ]]; then
    command -v gh >/dev/null 2>&1 || fail "GitHub CLI (gh) is required for --release. Install with 'brew install gh'."
    gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run 'gh auth login' first."
fi

# 2. Check Developer ID signing identity in Keychain
info "Verifying Developer ID signing identity in Keychain..."
identities=$(security find-identity -v -p codesigning)
[[ "$identities" == *"\"$sign_identity\""* ]] || fail "No valid local signing identity named '$sign_identity'. Check 'security find-identity -v -p codesigning'."

# 3. Check notarization credentials if not skipped
if [[ "$skip_notarize" -eq 0 ]]; then
    info "Verifying App Store Connect API credentials..."
    [[ -f "$key_path" ]] || fail "App Store Connect API key file not found: $key_path"
    [[ -n "$key_id" ]] || fail "App Store Connect Key ID must not be empty."
    [[ -n "$issuer_id" ]] || fail "App Store Connect Issuer ID must not be empty."

    # Enforce safe permissions on .p8
    chmod 600 "$key_path" 2>/dev/null || true
fi

# 4. Check project version and target DMG
proj_file="$root/MacDevCleaner.xcodeproj/project.pbxproj"
[[ -f "$proj_file" ]] || fail "Xcode project not found at $proj_file"

version=$(grep -m 1 'MARKETING_VERSION' "$proj_file" | sed -E 's/.*=[[:space:]]*([^;]+);/\1/' | tr -d ' "')
build=$(grep -m 1 'CURRENT_PROJECT_VERSION' "$proj_file" | sed -E 's/.*=[[:space:]]*([^;]+);/\1/' | tr -d ' "')
[[ -n "$version" && -n "$build" ]] || fail "Could not detect version or build number from project.pbxproj."

target_dmg="$root/dist/MacDevCleaner-$version-$build.dmg"
if [[ -e "$target_dmg" || -L "$target_dmg" ]]; then
    if [[ "$force" -ne 1 ]]; then
        fail "Target DMG already exists: $target_dmg\n       Increment CURRENT_PROJECT_VERSION in Xcode, or pass --force (-f) to overwrite."
    fi
fi

# 5. Create temporary work directory
work=$(mktemp -d "${TMPDIR:-/tmp}/MacDevCleaner-package.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 6. Archive Release scheme
archive_path="$work/MacDevCleaner.xcarchive"
info "Step 1/5: Archiving Release build (version $version, build $build)..."
xcodebuild archive \
    -project "$root/MacDevCleaner.xcodeproj" \
    -scheme "MacDevCleaner" \
    -configuration "Release" \
    -archivePath "$archive_path" \
    -quiet

[[ -d "$archive_path" ]] || fail "Archiving failed: $archive_path not found."

# 7. Export Developer ID application
info "Step 2/5: Exporting Developer ID application..."
export_options="$work/ExportOptions.plist"
cat << EOF > "$export_options"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$team_id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF

export_dir="$work/export"
xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options" \
    -quiet

exported_app="$export_dir/MacDevCleaner.app"
[[ -d "$exported_app" ]] || fail "Export failed: $exported_app not found."

# 8. Package into signed DMG
info "Step 3/5: Creating and signing DMG..."
FORCE="$force" /bin/bash "$root/scripts/package-dmg.sh" "$exported_app" "$sign_identity"

[[ -f "$target_dmg" ]] || fail "DMG packaging failed: $target_dmg not found."

# 9. Notarize with Apple Notary Service
if [[ "$skip_notarize" -eq 0 ]]; then
    info "Step 4/5: Submitting DMG to Apple Notary Service (waiting for completion)..."
    echo "  Archive:   $target_dmg"
    echo "  Key ID:    $key_id"
    echo "  Issuer ID: $issuer_id"

    xcrun notarytool submit "$target_dmg" \
        --key "$key_path" \
        --key-id "$key_id" \
        --issuer "$issuer_id" \
        --wait

    info "Step 5/5: Stapling notarization ticket and validating..."
    xcrun stapler staple "$target_dmg"
    xcrun stapler validate "$target_dmg"
    codesign --verify --strict --verbose=2 "$target_dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$target_dmg"
else
    info "Skipping notarization & stapling (--skip-notarize passed)"
fi

# 10. Generate SHA-256 Checksum
info "Generating SHA-256 checksum..."
shasum -a 256 "$target_dmg" > "$target_dmg.sha256"

# 11. Create GitHub Release & Upload Assets (Optional)
if [[ "$create_release" -eq 1 ]]; then
    info "Publishing GitHub Release via gh CLI..."
    release_tag="${release_tag:-$version}"
    release_title="${release_title:-$version}"

    gh_args=("$release_tag" "$target_dmg" "$target_dmg.sha256" "--title" "$release_title")

    if [[ -n "$release_notes_file" ]]; then
        gh_args+=("-F" "$release_notes_file")
    elif [[ -n "$release_notes" ]]; then
        gh_args+=("--notes" "$release_notes")
    else
        gh_args+=("--generate-notes")
    fi

    if [[ "$is_draft" -eq 1 ]]; then
        gh_args+=("--draft")
    fi

    if [[ "$is_prerelease" -eq 1 ]]; then
        gh_args+=("--prerelease")
    fi

    if gh release view "$release_tag" >/dev/null 2>&1; then
        if [[ "$force" -eq 1 ]]; then
            echo "Release '$release_tag' already exists on GitHub. Updating release assets (--clobber)..."
            gh release upload "$release_tag" "$target_dmg" "$target_dmg.sha256" --clobber
        else
            fail "GitHub Release '$release_tag' already exists. Increment version in Xcode, or pass --force (-f) to update release assets."
        fi
    else
        echo "Creating GitHub Release '$release_tag' and uploading release assets..."
        gh release create "${gh_args[@]}"
    fi

    release_url=$(gh release view "$release_tag" --json url -q .url 2>/dev/null || echo "https://github.com/jinyongnan810/MacDevCleaner/releases/tag/$release_tag")
fi

# 12. Final Summary
checksum=$(cat "$target_dmg.sha256")
dmg_size=$(ls -lh "$target_dmg" | awk '{print $5}')

printf '\n\033[1;32m==================================================\033[0m\n'
printf '\033[1;32mPackaging completed successfully!\033[0m\n'
printf '  Version:  %s (build %s)\n' "$version" "$build"
printf '  DMG:      %s (%s)\n' "$target_dmg" "$dmg_size"
printf '  SHA-256:  %s\n' "$checksum"
if [[ "$skip_notarize" -eq 0 ]]; then
    printf '  Status:   Signed, Notarized, and Stapled\n'
else
    printf '  Status:   Signed (Notarization skipped)\n'
fi
if [[ "$create_release" -eq 1 && -n "$release_url" ]]; then
    printf '  GitHub:   %s\n' "$release_url"
fi
printf '\033[1;32m==================================================\033[0m\n\n'
