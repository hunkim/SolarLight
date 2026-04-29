---
name: solarlight-release
description: Build, sign, notarize, staple, verify, and publish SolarLight macOS DMG releases. Use when releasing SolarLight, preparing a downloadable .dmg, checking Developer ID signing, validating Gatekeeper acceptance, uploading a GitHub Release asset, or repeating the known-good local release process without GitHub Actions.
---

# SolarLight Release

## Principle

Use the local release path. Do not rely on GitHub Actions for the release artifact unless the workflow also performs Developer ID signing, notarization, stapling, and downloaded-artifact verification. The known-good process is: build locally, sign with Developer ID, notarize with Apple, staple the DMG, upload to GitHub, download it back, and verify the copied app with Gatekeeper.

Never write app-specific passwords, Apple ID passwords, private keys, or certificate files into the repo, logs, skill files, release notes, or shell history. Create or use a `notarytool` keychain profile instead.

## Inputs

Set these per release:

```sh
VERSION=0.2.2
IDENTITY="<Developer ID Application identity from security find-identity>"
NOTARY_PROFILE="<notarytool keychain profile>"
REPO="hunkim/SolarLight"
```

Find the Developer ID identity:

```sh
security find-identity -v -p codesigning
```

If the notary profile is missing, create it interactively so the password is not stored in command text:

```sh
xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "<apple-id>" --team-id "<team-id>"
```

## Release Workflow

Start clean on `main`:

```sh
git status --short --branch
git pull --ff-only
```

Build the app bundle with the repo script:

```sh
SOLARLIGHT_VERSION="$VERSION" Scripts/package-app.sh
```

Replace the script's ad hoc signature with Developer ID signatures. If verification ever shows `Authority=(unavailable)`, clear attributes/signatures and sign again outside restricted sandboxes.

```sh
xattr -cr .build/SolarLight.app
codesign --remove-signature .build/SolarLight.app/Contents/MacOS/SolarLight || true
codesign --remove-signature .build/SolarLight.app || true
codesign --force --timestamp --options runtime --sign "$IDENTITY" .build/SolarLight.app/Contents/MacOS/SolarLight
codesign --force --timestamp --options runtime --sign "$IDENTITY" .build/SolarLight.app
codesign --verify --deep --strict --verbose=4 .build/SolarLight.app
codesign -dv --verbose=4 .build/SolarLight.app
```

Before notarization, `spctl` may reject with `source=Unnotarized Developer ID`. That is expected:

```sh
spctl -a -vvv -t exec .build/SolarLight.app
```

Create a DMG from the already-signed app. Avoid rerunning `Scripts/package-dmg.sh` after signing because it rebuilds the app and can replace the Developer ID signature.

```sh
rm -rf .build/dmg ".build/SolarLight-$VERSION.dmg"
mkdir -p .build/dmg
cp -R .build/SolarLight.app .build/dmg/SolarLight.app
ln -s /Applications .build/dmg/Applications
hdiutil create -volname SolarLight -srcfolder .build/dmg -ov -format UDZO ".build/SolarLight-$VERSION.dmg"
codesign --force --timestamp --sign "$IDENTITY" ".build/SolarLight-$VERSION.dmg"
codesign --verify --verbose=4 ".build/SolarLight-$VERSION.dmg"
hdiutil verify ".build/SolarLight-$VERSION.dmg"
```

Submit, wait, and staple:

```sh
xcrun notarytool submit ".build/SolarLight-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple ".build/SolarLight-$VERSION.dmg"
xcrun stapler validate ".build/SolarLight-$VERSION.dmg"
```

## Required Local Verification

Verify the user path, not only the local app bundle:

```sh
rm -rf "/tmp/SolarLight-$VERSION-verify.app" "/tmp/SolarLight-$VERSION-mount"
mkdir -p "/tmp/SolarLight-$VERSION-mount"
hdiutil attach ".build/SolarLight-$VERSION.dmg" -mountpoint "/tmp/SolarLight-$VERSION-mount" -nobrowse -readonly
cp -R "/tmp/SolarLight-$VERSION-mount/SolarLight.app" "/tmp/SolarLight-$VERSION-verify.app"
codesign --verify --deep --strict --verbose=4 "/tmp/SolarLight-$VERSION-verify.app"
codesign -dv --verbose=4 "/tmp/SolarLight-$VERSION-verify.app"
spctl -a -vvv -t exec "/tmp/SolarLight-$VERSION-verify.app"
plutil -extract CFBundleShortVersionString raw "/tmp/SolarLight-$VERSION-verify.app/Contents/Info.plist"
hdiutil detach "/tmp/SolarLight-$VERSION-mount"
```

Success requires:

- `codesign --verify`: valid on disk and satisfies designated requirement
- `codesign -dv`: Developer ID Application authority chain, timestamp, TeamIdentifier, hardened runtime
- `spctl -t exec`: `accepted`, `source=Notarized Developer ID`
- `Info.plist`: version equals `$VERSION`

## Publish

Only publish after local verification passes.

```sh
git tag "v$VERSION"
git push origin "v$VERSION"
gh release view "v$VERSION" >/dev/null 2>&1 || gh release create "v$VERSION" --title "v$VERSION" --notes "SolarLight macOS release."
gh release upload "v$VERSION" ".build/SolarLight-$VERSION.dmg" --clobber
```

Then download the release asset and repeat verification:

```sh
rm -rf "/tmp/SolarLight-$VERSION-release-check" "/tmp/SolarLight-$VERSION-release-mount" "/tmp/SolarLight-$VERSION-release.app"
mkdir -p "/tmp/SolarLight-$VERSION-release-check" "/tmp/SolarLight-$VERSION-release-mount"
curl -L -o "/tmp/SolarLight-$VERSION-release-check/SolarLight-$VERSION.dmg" "https://github.com/$REPO/releases/download/v$VERSION/SolarLight-$VERSION.dmg"
shasum -a 256 "/tmp/SolarLight-$VERSION-release-check/SolarLight-$VERSION.dmg"
codesign --verify --verbose=4 "/tmp/SolarLight-$VERSION-release-check/SolarLight-$VERSION.dmg"
xcrun stapler validate "/tmp/SolarLight-$VERSION-release-check/SolarLight-$VERSION.dmg"
hdiutil verify "/tmp/SolarLight-$VERSION-release-check/SolarLight-$VERSION.dmg"
hdiutil attach "/tmp/SolarLight-$VERSION-release-check/SolarLight-$VERSION.dmg" -mountpoint "/tmp/SolarLight-$VERSION-release-mount" -nobrowse -readonly
cp -R "/tmp/SolarLight-$VERSION-release-mount/SolarLight.app" "/tmp/SolarLight-$VERSION-release.app"
codesign --verify --deep --strict --verbose=4 "/tmp/SolarLight-$VERSION-release.app"
spctl -a -vvv -t exec "/tmp/SolarLight-$VERSION-release.app"
plutil -extract CFBundleShortVersionString raw "/tmp/SolarLight-$VERSION-release.app/Contents/Info.plist"
hdiutil detach "/tmp/SolarLight-$VERSION-release-mount"
```

If a GitHub-created asset exists and has a different SHA-256 from the locally verified DMG, replace it with `gh release upload --clobber` and verify the downloaded asset again.
