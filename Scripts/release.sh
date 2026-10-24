#!/usr/bin/env bash
# Archive → export with Developer ID (Xcode automatic signing, embedded profile with iCloud) →
# check the signature and entitlements → DMG → notarize → staple. No Sparkle auto-update.
#
# Usage:   CLOUDKIT_SCHEMA_DEPLOYED=1 ./Scripts/release.sh <version>
# Example: CLOUDKIT_SCHEMA_DEPLOYED=1 ./Scripts/release.sh 1.0.0
#
# CLOUDKIT_SCHEMA_DEPLOYED=1 says the CloudKit schema of this build was deployed to Production in
# CloudKit Console (T6.2, iCloud.fr.vincentlauriat.remotedeck): a release whose record types or
# fields are missing in Production cannot sync. The script refuses to run without it.
#
# Reuses Vincent's shared Apple credentials (same account for all Mac apps):
#   - Developer ID Application: Vincent LAURIAT (KFLACS69T9)
#   - notary keychain profile "AppliMacVincentGithub" (apple-id vincent@lauriat.fr)
# If you ever need to recreate the profile:
#   xcrun notarytool store-credentials "AppliMacVincentGithub" \
#     --apple-id "vincent@lauriat.fr" --team-id "KFLACS69T9"
#
# Overridable via env: APP_NAME, SCHEME, PROJECT, SIGNING_IDENTITY (checked, not chosen: the export
# uses the team's Developer ID Application identity), NOTARY_PROFILE
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>   (e.g. $0 1.0.0)" >&2
  exit 1
fi
if [ "${CLOUDKIT_SCHEMA_DEPLOYED:-}" != "1" ]; then
  echo "✗ Deploy the CloudKit schema to Production first (CloudKit Console, T6.2), then rerun with CLOUDKIT_SCHEMA_DEPLOYED=1" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ── Project identity (bootstrap.sh rewrites these when you clone the template) ──
APP_NAME="${APP_NAME:-RemoteDeck}"      # PRODUCT_NAME / .app bundle name
SCHEME="${SCHEME:-RemoteDeck}"           # macOS scheme (see project.yml)
PROJECT="${PROJECT:-RemoteDeck.xcodeproj}"

DMG_SLUG="$(echo "$APP_NAME" | tr -d ' ')"
DMG_VOLNAME="$APP_NAME $VERSION"
RELEASE_DIR="$ROOT/release"
mkdir -p "$RELEASE_DIR"
DMG="$RELEASE_DIR/$DMG_SLUG-$VERSION.dmg"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▶︎ Releasing $APP_NAME $VERSION (build $BUILD_NUMBER)"

# 1. Regenerate the Xcode project from project.yml
echo "▶︎ xcodegen generate"
xcodegen generate >/dev/null

# 2. Archive Release, then export it for Developer ID (T4.3). Xcode's automatic signing provisions
#    the App ID (iCloud/CloudKit, push, keychain group) and the Developer ID profile that iCloud
#    needs: a manual `codesign` of the raw entitlements file would leave `$(AppIdentifierPrefix)`
#    unexpanded and no embedded profile, and the app would be killed at launch.
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ARCHIVE="$STAGING_DIR/$APP_NAME.xcarchive"
echo "▶︎ xcodebuild archive (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates archive >/dev/null

# 3. Export with Developer ID (Hardened Runtime, secure timestamp, embedded profile).
echo "▶︎ xcodebuild -exportArchive (developer-id)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$STAGING_DIR/export" \
  -exportOptionsPlist "$ROOT/Scripts/ExportOptions-DeveloperID.plist" \
  -allowProvisioningUpdates >/dev/null
EXPORTED="$STAGING_DIR/export/$APP_NAME.app"
[ -d "$EXPORTED" ] || { echo "✗ Exported app not found: $EXPORTED" >&2; exit 1; }
STAGING="$STAGING_DIR/$APP_NAME.app"
ditto --norsrc --noextattr --noacl "$EXPORTED" "$STAGING"

# 4. Check the signature: Developer ID, sandbox, iCloud container in Production, embedded profile.
echo "▶︎ check signature and entitlements"
codesign --verify --strict --deep --verbose=1 "$STAGING"
# Captured first: `grep -q` closing the pipe early would SIGPIPE codesign under pipefail.
SIGNATURE="$(codesign -dvv "$STAGING" 2>&1)"
grep -q "Authority=$SIGNING_IDENTITY" <<<"$SIGNATURE" \
  || { echo "✗ not signed with $SIGNING_IDENTITY" >&2; exit 1; }
[ -f "$STAGING/Contents/embedded.provisionprofile" ] \
  || { echo "✗ no embedded Developer ID provisioning profile" >&2; exit 1; }
codesign -d --entitlements - --xml "$STAGING" 2>/dev/null \
  | python3 -I -c 'import plistlib,sys; d=sys.stdin.buffer.read(); sys.exit(0 if d and plistlib.loads(d).get("com.apple.security.app-sandbox") is True else 1)' \
  || { echo "✗ sandbox entitlement missing from signed app" >&2; exit 1; }
codesign -d --entitlements - --xml "$STAGING" 2>/dev/null \
  | python3 -I -c 'import plistlib,sys
d = plistlib.loads(sys.stdin.buffer.read())
ok = ("iCloud.fr.vincentlauriat.remotedeck" in d.get("com.apple.developer.icloud-container-identifiers", [])
      and "CloudKit" in d.get("com.apple.developer.icloud-services", [])
      and d.get("com.apple.developer.icloud-container-environment") == "Production"
      and d.get("com.apple.developer.aps-environment") == "production")
sys.exit(0 if ok else 1)' \
  || { echo "✗ iCloud entitlements (container, CloudKit, Production container, production push) missing from signed app" >&2; exit 1; }

# 5. Build the DMG with a custom Finder layout
echo "▶︎ build DMG"
DMG_LAYOUT="$STAGING_DIR/dmg-layout"
mkdir -p "$DMG_LAYOUT/.background"
ditto --norsrc --noextattr --noacl "$STAGING" "$DMG_LAYOUT/$APP_NAME.app"
ln -s /Applications "$DMG_LAYOUT/Applications"
"$ROOT/Scripts/make-dmg-background.swift" "$DMG_LAYOUT/.background/background.png" >/dev/null

RW_DMG="$STAGING_DIR/temp.dmg"
hdiutil create -volname "$DMG_VOLNAME" -srcfolder "$DMG_LAYOUT" \
  -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

MOUNT="$(hdiutil attach -nobrowse -noverify -noautoopen "$RW_DMG" | awk -F '\t' 'END {print $NF}')"
osascript <<APPLESCRIPT >/dev/null || true
tell application "Finder"
    tell disk "$DMG_VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 100, 740, 480}
        set view_options to the icon view options of container window
        set arrangement of view_options to not arranged
        set icon size of view_options to 128
        set background picture of view_options to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {140, 200}
        set position of item "Applications" of container window to {400, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null

# 6. Notarize + staple
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
✗ Notary profile "$NOTARY_PROFILE" not found.
  Create it once (interactive):
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "vincent@lauriat.fr" --team-id "KFLACS69T9"
  The DMG was built and signed at: $DMG (NOT yet notarized).
EOF
  exit 1
fi
echo "▶︎ notarize (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "▶︎ staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo
echo "✅ Built, signed, notarized & stapled: $(basename "$DMG") ($SIZE)"
echo
echo "Publish on GitHub:"
echo "  gh release create v$VERSION \"$DMG\" --title \"v$VERSION\" --generate-notes"
