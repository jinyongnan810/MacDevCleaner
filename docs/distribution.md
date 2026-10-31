# DMG release guide

MacDevCleaner ships as a signed, notarized DMG. Users drag the app into Applications and launch it. Requires macOS 27.0 or later; Full Disk Access remains a separate user permission.

## One-time setup

### Signing certificate

1. Join the Apple Developer Program and add your account in Xcode Settings > Accounts.
2. Select your team > Manage Certificates > **+ > Developer ID Application**. The Account Holder may need to create it.
3. List local signing identities:

   ```sh
   security find-identity -v -p codesigning
   ```

Copy the exact **Developer ID Application** identity for packaging. It must include a local private key; Apple Development is insufficient. When importing from another Mac, use a protected `.p12` containing both certificate and private key.

### Notarization credentials

Install [asc](https://github.com/rudrankriyam/App-Store-Connect-CLI), then:

1. In App Store Connect, open **Users and Access > Integrations > App Store Connect API > Team Keys**.
2. Generate a key named `MacDevCleaner Notarization` with **Developer** access. If API access is disabled, the Account Holder must request it first.
3. Download the `.p8` (available only once), and copy the **Key ID** and **Issuer ID**. Issuer ID differs from Team ID.
4. Keep the key outside the repository and register it:

   ```sh
   chmod 600 /absolute/path/AuthKey_KEYID.p8
   asc auth login --name macdevcleaner-release \
     --key-id YOUR_KEY_ID \
     --issuer-id YOUR_ISSUER_ID \
     --private-key /absolute/path/AuthKey_KEYID.p8
   ```

## Each release

### 1. Export from Xcode

1. Open `MacDevCleaner.xcodeproj` and select your signing team. Keep automatic signing enabled, **App Sandbox off**, and **Hardened Runtime on**.
2. Set **Version** and increment **Build** (digits and dots only).
3. Select **MacDevCleaner**, confirm Archive uses **Release**, then choose **Product > Archive**.
4. In Organizer, use **Distribute App > Custom > Developer ID** and export the signed app. Labels vary by Xcode version. Keep the archive and dSYMs.

### 2. Package

From the repository root, substitute your export path and exact certificate name:

```sh
make dmg \
  APP="$HOME/Desktop/MacDevCleaner-export/MacDevCleaner.app" \
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Output: `dist/MacDevCleaner-<version>-<build>.dmg`. The script checks the app, adds an Applications shortcut, and signs the image. Existing outputs are never overwritten.

### 3. Notarize and staple

Update `DMG` to match your release filename:

```sh
DMG="dist/MacDevCleaner-1.0-1.dmg"
asc --profile macdevcleaner-release notarization submit --file "$DMG" --wait
```

Wait for **Accepted**, then:

```sh
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
```

If submission fails or times out, check the submission ID before retrying:

```sh
asc --profile macdevcleaner-release notarization status --id SUBMISSION_ID
asc --profile macdevcleaner-release notarization log --id SUBMISSION_ID
```

### 4. Verify and publish

1. Upload the stapled DMG to a draft release. Download it through a browser on a clean, supported Mac to exercise Gatekeeper.
2. Drag the app into Applications, eject the image, and launch. Check scanning, copying commands, and Scan access. Also check offline installation from the stapled DMG.
3. Verify the installed app and supported architectures:

   ```sh
   codesign --verify --deep --strict --verbose=2 /Applications/MacDevCleaner.app
   spctl --assess --type execute --verbose=2 /Applications/MacDevCleaner.app
   lipo -archs /Applications/MacDevCleaner.app/Contents/MacOS/MacDevCleaner
   ```

4. Generate the checksum **after stapling**:

   ```sh
   shasum -a 256 "$DMG" > "$DMG.sha256"
   ```

5. Publish the DMG, checksum, and release notes with the minimum macOS version and supported architectures. Keep the final DMG unchanged. Updates use download-and-replace.

See Apple's guides for [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api), and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
