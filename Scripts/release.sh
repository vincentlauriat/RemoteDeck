#!/usr/bin/env bash
# Archive → export with Developer ID (Xcode automatic signing, embedded profile with iCloud) →
# check version, signature and entitlements (Sparkle's nested helpers included) → DMG (dmgbuild) →
# notarize → staple → spctl → Sparkle EdDSA signature → appcast.xml item.
#
# ┌──────────────────────────────────────────────────────────────────────────┐
# │ SPARKLE SIGNING KEY — DO NOT REGENERATE                                  │
# │                                                                          │
# │ Updates are EdDSA-signed with the private key in the login keychain      │
# │ under the account "RemoteDeck" (generated 2026-10-25, Sparkle 2.10.0).   │
# │ Its public half is SUPublicEDKey in project.yml (the only copy to edit:  │
# │ never).                                                                  │
# │                                                                          │
# │ NEVER run `generate_keys` again for this account, NEVER import another   │
# │ key into it and NEVER change SUPublicEDKey: every installed copy would   │
# │ reject all later updates. Back the private key up once, somewhere safe   │
# │ and outside the repository:                                              │
# │     generate_keys --account RemoteDeck -x <backup file>                  │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Usage:   CLOUDKIT_SCHEMA_DEPLOYED=1 ./Scripts/release.sh <version>
#          ./Scripts/release.sh --dry-run <version>
#          ./Scripts/release.sh --check-sparkle-signatures <path/to/RemoteDeck.app>
# Example: CLOUDKIT_SCHEMA_DEPLOYED=1 ./Scripts/release.sh 1.0.0
#
# project.yml is the source of truth: <version> must equal MARKETING_VERSION, and
# CURRENT_PROJECT_VERSION (the build number Sparkle compares) must be above every
# <sparkle:version> in appcast.xml (working tree, HEAD and origin/main). Bump both in project.yml
# before a release; the script checks both again in the exported app's Info.plist.
#
# A real run needs a clean, committed tree (appcast.xml and the release notes excepted), an
# appcast.xml identical to HEAD (no unpublished previous run), and release notes in
# release/release-notes-<version>.md (a template is written there the first time; the run stops
# until it is filled in). It records the commit it built and prints the `gh release create`
# command targeting it.
#
# CLOUDKIT_SCHEMA_DEPLOYED=1 says the CloudKit schema of this build was deployed to Production in
# CloudKit Console (T6.2, iCloud.fr.vincentlauriat.remotedeck): a release whose record types or
# fields are missing in Production cannot sync. A real release refuses to run without it.
#
# --dry-run runs every step up to, not including, notarization (archive, export, every check, the
# signed DMG) with the DMG in a throwaway directory: nothing is written to release/ or
# appcast.xml, nothing is uploaded; like any build it regenerates RemoteDeck.xcodeproj and writes
# build/ (both git-ignored). The archive and export still use -allowProvisioningUpdates (an
# unlocked session with Xcode's account), as the real run does.
#
# --check-sparkle-signatures only checks Sparkle's nested helpers in an existing app (Developer ID
# authority, hardened runtime, secure timestamp, no get-task-allow) and exits.
#
# Reuses the maintainer's shared Apple credentials (same account for all Mac apps):
#   - Developer ID Application: Vincent LAURIAT (KFLACS69T9)
#   - the existing notary keychain profile "AppliMacVincentGithub"
# If you ever need to recreate the profile, pass your own Apple ID:
#   xcrun notarytool store-credentials "AppliMacVincentGithub" \
#     --apple-id "<your Apple ID>" --team-id "KFLACS69T9"
#
# Overridable via env: APP_NAME, SCHEME, PROJECT, SIGNING_IDENTITY (checked, not chosen: the export
# uses the team's Developer ID Application identity), NOTARY_PROFILE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="${APP_NAME:-RemoteDeck}"      # PRODUCT_NAME / .app bundle name
SCHEME="${SCHEME:-RemoteDeck}"           # macOS scheme (see project.yml)
PROJECT="${PROJECT:-RemoteDeck.xcodeproj}"
BUNDLE_ID="fr.vincentlauriat.remotedeck"
GITHUB_REPO="vincentlauriat/RemoteDeck"
SPARKLE_ACCOUNT="RemoteDeck"
MIN_SYSTEM_VERSION="15.0"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Vincent LAURIAT (KFLACS69T9)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AppliMacVincentGithub}"
# Keep in step with the Sparkle package pinned in project.yml (exactVersion).
SPARKLE_VERSION="2.10.0"
# sign_update reads the private EdDSA key: never run an unverified download. SHA-256 of the exact
# tarball below, as GitHub publishes it for the release asset; update both lines together.
SPARKLE_TARBALL_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

# ── Sparkle's nested helpers ────────────────────────────────────────────────────────────────────
# Sparkle ships Installer.xpc, Downloader.xpc, Autoupdate and Updater.app ad-hoc signed. An Xcode
# archive + export re-signs them (Sparkle › Sandboxing › Code Signing); a deep verify passes even
# when they are not, and notarization rejects them later. Each must carry the Developer ID
# authority, the hardened runtime, a secure timestamp, and no get-task-allow.
sparkle_helpers() {
  local v="$1/Contents/Frameworks/Sparkle.framework/Versions/B"
  # Sparkle's documented signing order (innermost first).
  printf '%s\n' "$v/XPCServices/Installer.xpc" "$v/XPCServices/Downloader.xpc" \
    "$v/Autoupdate" "$v/Updater.app" "$1/Contents/Frameworks/Sparkle.framework"
}

check_signed() {
  local target="$1" details entitlements
  [ -e "$target" ] || { echo "  ✗ missing: $target" >&2; return 1; }
  details="$(codesign -dvv "$target" 2>&1)" || { echo "  ✗ not signed: $target" >&2; return 1; }
  entitlements="$(codesign -d --entitlements - --xml "$target" 2>/dev/null || true)"
  DETAILS="$details" ENTITLEMENTS="$entitlements" IDENTITY="$SIGNING_IDENTITY" TARGET="$target" python3 -I -c '
import os, plistlib, re, sys
details, target = os.environ["DETAILS"], os.environ["TARGET"]
lines = details.splitlines()
problems = []
if "Authority=" + os.environ["IDENTITY"] not in lines:
    problems.append("authority is not " + os.environ["IDENTITY"])
flags = [l for l in lines if l.startswith("CodeDirectory ")]
if not flags or not re.search(r"flags=0x[0-9a-f]+\([^)]*\bruntime\b", flags[0]):
    problems.append("no hardened runtime")
if not any(l.startswith("Timestamp=") for l in lines):
    problems.append("no secure timestamp")
raw = os.environ["ENTITLEMENTS"].encode()
if raw.strip():
    try:
        if plistlib.loads(raw).get("com.apple.security.get-task-allow") is True:
            problems.append("get-task-allow")
    except Exception:
        problems.append("unreadable entitlements")
for p in problems:
    print("  ✗ %s: %s" % (target, p), file=sys.stderr)
sys.exit(1 if problems else 0)'
}

check_sparkle_signatures() {
  local app="$1" ok=0 target
  while IFS= read -r target; do
    check_signed "$target" || ok=1
  done < <(sparkle_helpers "$app")
  return "$ok"
}

if [ "${1:-}" = "--check-sparkle-signatures" ]; then
  [ -d "${2:-}" ] || { echo "usage: $0 --check-sparkle-signatures <path/to/App.app>" >&2; exit 1; }
  if check_sparkle_signatures "$2"; then echo "✓ Sparkle helpers signed: $2"; else exit 1; fi
  exit 0
fi

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 [--dry-run] <version>   (e.g. $0 1.0.0)" >&2
  exit 1
fi
if [ "$DRY_RUN" = 0 ] && [ "${CLOUDKIT_SCHEMA_DEPLOYED:-}" != "1" ]; then
  echo "✗ Deploy the CloudKit schema to Production first (CloudKit Console, T6.2), then rerun with CLOUDKIT_SCHEMA_DEPLOYED=1" >&2
  exit 1
fi

# ── 0. Toolchain, tree and version checks (before any build) ────────────────────────────────────
XCODE_DIR="$(xcode-select -p)"
if printf '%s' "$XCODE_DIR" | grep -qi "beta"; then
  echo "✗ xcode-select points to a beta Xcode ($XCODE_DIR): select the stable one (sudo xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
fi
XCODE_VERSION="$(xcodebuild -version | head -1)"
XCODE_BUILD="$(xcodebuild -version | sed -n 2p | awk '{print $NF}')"
# A beta renamed to Xcode.app passes the path check. Neither its Info.plist nor its version.plist
# carries a key that tells a beta apart (checked 2026-10-25 on 27.1 / 27A9275: CFBundleShortVersionString,
# CFBundleVersion, ProductBuildVersion, DTXcodeBuild only), and build letters mean nothing (stable
# 16.2 is 16C5032a). So: a name or version string saying "beta" refuses, anything else is printed
# for the operator to confirm against Apple's release list.
XCODE_APP="$(cd "$XCODE_DIR/../.." && pwd)"
XCODE_MARKER="$(python3 -I -c '
import plistlib, sys
app = sys.argv[1]
values = []
for name in ("Info.plist", "version.plist"):
    try:
        d = plistlib.load(open(app + "/Contents/" + name, "rb"))
    except (OSError, ValueError):
        continue
    values += [str(v) for k, v in d.items() if isinstance(v, str) and ("Version" in k or "Name" in k)]
print("beta" if any("beta" in v.lower() for v in values + [app]) else "")' "$XCODE_APP")"
if [ -n "$XCODE_MARKER" ]; then
  echo "✗ $XCODE_APP says it is a beta: select a stable Xcode" >&2
  exit 1
fi
echo "  ⚠︎ $XCODE_VERSION ($XCODE_BUILD) at $XCODE_APP: no beta marker found; confirm it is a stable release"
command -v xcodegen >/dev/null || { echo "✗ XcodeGen not installed (brew install xcodegen)" >&2; exit 1; }

# MARKETING_VERSION and CURRENT_PROJECT_VERSION of the app target, read from project.yml.
YML_VERSIONS="$(python3 -I -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
def one(key):
    values = set(re.findall(r"^\s+%s:\s*\"?([^\"\s#]+)\"?" % key, text, re.M))
    if len(values) != 1:
        sys.exit("✗ expected one %s in project.yml, found %s" % (key, sorted(values)))
    return values.pop()
print(one("MARKETING_VERSION"), one("CURRENT_PROJECT_VERSION"), sep="\t")' "$ROOT/project.yml")"
YML_VERSION="$(printf '%s' "$YML_VERSIONS" | cut -f1)"
BUILD_NUMBER="$(printf '%s' "$YML_VERSIONS" | cut -f2)"
if [ "$YML_VERSION" != "$VERSION" ]; then
  echo "✗ MARKETING_VERSION in project.yml is $YML_VERSION, not $VERSION: bump project.yml first" >&2
  exit 1
fi
NOTES="$ROOT/release/release-notes-$VERSION.md"

if [ "$DRY_RUN" = 0 ]; then
  # An appcast.xml that differs from HEAD is a previous run that was never published.
  if ! git diff --quiet HEAD -- appcast.xml; then
    echo "✗ appcast.xml differs from HEAD (an unpublished previous run?): publish and commit it, or git restore appcast.xml" >&2
    exit 1
  fi
  # Everything else must be committed, so the recorded commit is what was built.
  DIRTY="$(git status --porcelain --untracked-files=all | python3 -I -c '
import sys
skip = {"appcast.xml", sys.argv[1]}
print("\n".join(l for l in sys.stdin.read().splitlines() if l[3:] not in skip))' "release/release-notes-$VERSION.md")"
  if [ -n "$DIRTY" ]; then
    echo "✗ the tree is not clean (commit or stash first):" >&2
    echo "$DIRTY" | sed "s/^/    /" >&2
    exit 1
  fi
  if [ ! -s "$NOTES" ]; then
    mkdir -p "$ROOT/release"
    cat > "$NOTES" <<EOF
<!-- RemoteDeck $VERSION release notes: replace this whole file, then rerun release.sh. -->
## What's new

-

## Fixes

-
EOF
    echo "✗ write the release notes first: $NOTES (template created)" >&2
    exit 1
  fi
  if grep -q "replace this whole file" "$NOTES"; then
    echo "✗ $NOTES is still the template: write the notes, then rerun" >&2
    exit 1
  fi
fi
BUILT_SHA="$(git rev-parse HEAD)"

# Sparkle compares <sparkle:version> (CFBundleVersion) numerically and silently refuses an update
# whose build is not higher. The highest build and every version already listed, across the
# working tree, HEAD and origin/main (fetched first when online).
if ! git fetch --quiet origin main 2>/dev/null; then
  echo "  ⚠︎ git fetch origin main failed (offline?): origin/main may be stale"
fi
PUBLISHED="$( {
  for REF in "WORKTREE" "HEAD" "origin/main"; do
    if [ "$REF" = "WORKTREE" ]; then cat appcast.xml 2>/dev/null || true; else git show "$REF:appcast.xml" 2>/dev/null || true; fi
    printf '\n\x1e\n'
  done
} | python3 -I -c '
import sys, xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
builds, shorts = [0], set()
for text in sys.stdin.read().split("\x1e"):
    if not text.strip():
        continue
    for i in ET.fromstring(text.strip()).findall("./channel/item"):
        v = (i.findtext(ns + "version") or "").strip()
        if v.isdigit():
            builds.append(int(v))
        shorts.add((i.findtext(ns + "shortVersionString") or "").strip())
print(max(builds), " ".join(sorted(s for s in shorts if s)), sep="\t")')"
PUBLISHED_BUILD="$(printf '%s' "$PUBLISHED" | cut -f1)"
PUBLISHED_VERSIONS="$(printf '%s' "$PUBLISHED" | cut -f2)"
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || [ "$BUILD_NUMBER" -le "$PUBLISHED_BUILD" ]; then
  echo "✗ CURRENT_PROJECT_VERSION ($BUILD_NUMBER) must be an integer above the published build $PUBLISHED_BUILD: bump it in project.yml" >&2
  exit 1
fi
for V in $PUBLISHED_VERSIONS; do
  [ "$V" != "$VERSION" ] || { echo "✗ $VERSION is already in appcast.xml" >&2; exit 1; }
done

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
if [ "$DRY_RUN" = 1 ]; then
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remotedeck-dryrun.XXXXXX")"
else
  OUT_DIR="$ROOT/release"
fi
mkdir -p "$OUT_DIR"
DMG_SLUG="$(echo "$APP_NAME" | tr -d ' ')"
DMG_VOLNAME="$APP_NAME $VERSION"
DMG="$OUT_DIR/$DMG_SLUG-$VERSION.dmg"

echo "▶︎ $([ "$DRY_RUN" = 1 ] && echo "Dry run: " || true)$APP_NAME $VERSION (build $BUILD_NUMBER) from $BUILT_SHA, $XCODE_VERSION at $XCODE_DIR"

# ── 1. Regenerate the Xcode project from project.yml ────────────────────────────────────────────
echo "▶︎ xcodegen generate"
xcodegen generate >/dev/null

# ── 2. Archive Release, then export it for Developer ID (T4.3) ──────────────────────────────────
# Xcode's automatic signing provisions the App ID (iCloud/CloudKit, push, keychain group) and the
# Developer ID profile that iCloud needs: a manual `codesign` of the raw entitlements file would
# leave `$(AppIdentifierPrefix)` unexpanded and no embedded profile, and the app would be killed at
# launch. No MARKETING_VERSION / CURRENT_PROJECT_VERSION override: project.yml decides.
ARCHIVE="$STAGING_DIR/$APP_NAME.xcarchive"
echo "▶︎ xcodebuild archive (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive >/dev/null

# ── 3. Export with Developer ID (hardened runtime, secure timestamp, embedded profile) ──────────
echo "▶︎ xcodebuild -exportArchive (developer-id)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$STAGING_DIR/export" \
  -exportOptionsPlist "$ROOT/Scripts/ExportOptions-DeveloperID.plist" \
  -allowProvisioningUpdates >/dev/null
EXPORTED="$STAGING_DIR/export/$APP_NAME.app"
[ -d "$EXPORTED" ] || { echo "✗ Exported app not found: $EXPORTED" >&2; exit 1; }
STAGING="$STAGING_DIR/$APP_NAME.app"
ditto --norsrc --noextattr --noacl "$EXPORTED" "$STAGING"

# ── 4. Version, build number and Sparkle keys in the built Info.plist ───────────────────────────
echo "▶︎ check Info.plist (version $VERSION, build $BUILD_NUMBER, Sparkle keys)"
python3 -I -c '
import plistlib, re, sys
info = plistlib.load(open(sys.argv[1], "rb"))
yml = open(sys.argv[2], encoding="utf-8").read()
key = re.search(r"SUPublicEDKey:\s*\"([^\"]+)\"", yml).group(1)
feed = re.search(r"SUFeedURL:\s*\"([^\"]+)\"", yml).group(1)
expected = {
    "CFBundleIdentifier": sys.argv[5],
    "CFBundleShortVersionString": sys.argv[3],
    "CFBundleVersion": sys.argv[4],
    "LSMinimumSystemVersion": sys.argv[6],
    "SUPublicEDKey": key,
    "SUFeedURL": feed,
    "SUEnableInstallerLauncherService": True,
}
bad = ["%s = %r, expected %r" % (k, info.get(k), v) for k, v in expected.items() if info.get(k) != v]
if info.get("SUEnableDownloaderService"):
    bad.append("SUEnableDownloaderService must stay off (network.client is granted)")
for b in bad:
    print("✗ Info.plist: " + b, file=sys.stderr)
sys.exit(1 if bad else 0)' "$STAGING/Contents/Info.plist" "$ROOT/project.yml" "$VERSION" "$BUILD_NUMBER" \
  "$BUNDLE_ID" "$MIN_SYSTEM_VERSION"

# ── 5. Signature: Developer ID, sandbox, iCloud in Production, Sparkle installer, profile ───────
echo "▶︎ check signature and entitlements"
# Captured first: `grep -q` closing the pipe early would SIGPIPE codesign under pipefail.
SIGNATURE="$(codesign -dvv "$STAGING" 2>&1)"
grep -q "Authority=$SIGNING_IDENTITY" <<<"$SIGNATURE" \
  || { echo "✗ not signed with $SIGNING_IDENTITY" >&2; exit 1; }
[ -f "$STAGING/Contents/embedded.provisionprofile" ] \
  || { echo "✗ no embedded Developer ID provisioning profile" >&2; exit 1; }
codesign -d --entitlements - --xml "$STAGING" 2>/dev/null | BUNDLE_ID="$BUNDLE_ID" python3 -I -c '
import os, plistlib, sys
raw = sys.stdin.buffer.read()
d = plistlib.loads(raw) if raw else {}
bid = os.environ["BUNDLE_ID"]
checks = {
    "sandbox": d.get("com.apple.security.app-sandbox") is True,
    "network.client": d.get("com.apple.security.network.client") is True,
    "iCloud container": "iCloud.fr.vincentlauriat.remotedeck" in d.get("com.apple.developer.icloud-container-identifiers", []),
    "CloudKit": "CloudKit" in d.get("com.apple.developer.icloud-services", []),
    "iCloud Production": d.get("com.apple.developer.icloud-container-environment") == "Production",
    "push production": d.get("com.apple.developer.aps-environment") == "production",
    # Expanded by Xcode: an unexpanded $(PRODUCT_BUNDLE_IDENTIFIER) would install silently broken.
    "Sparkle installer mach-lookup": sorted(d.get("com.apple.security.temporary-exception.mach-lookup.global-name", []))
        == sorted([bid + "-spks", bid + "-spki"]),
    "no get-task-allow": d.get("com.apple.security.get-task-allow") is not True,
}
for name, ok in checks.items():
    if not ok:
        print("✗ entitlement check failed: " + name, file=sys.stderr)
sys.exit(0 if all(checks.values()) else 1)'

codesign_ts() {
  local i
  for i in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$@"; then
      return 0
    fi
    echo "  …codesign retry $i/5 (timestamp server) in 5s" >&2
    sleep 5
  done
  echo "✗ codesign failed: $*" >&2
  return 1
}

echo "▶︎ check Sparkle's nested helpers"
if ! check_sparkle_signatures "$STAGING"; then
  # Fallback only: Sparkle's manual order, never --deep. Downloader.xpc keeps its own entitlements
  # (Sparkle ≥ 2.6); the app keeps its expanded entitlements, requirements and flags, so the
  # embedded profile still matches.
  echo "▶︎ re-signing Sparkle's helpers (the export left them unsigned)"
  V="$STAGING/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign_ts "$V/XPCServices/Installer.xpc"
  codesign_ts --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
  codesign_ts "$V/Autoupdate"
  codesign_ts "$V/Updater.app"
  codesign_ts "$STAGING/Contents/Frameworks/Sparkle.framework"
  codesign_ts --preserve-metadata=entitlements,requirements,flags "$STAGING"
  check_sparkle_signatures "$STAGING" || { echo "✗ Sparkle helpers still not signed correctly" >&2; exit 1; }
fi
codesign --verify --deep --strict --verbose=1 "$STAGING"

# ── 6. DMG with a Finder layout, by dmgbuild ────────────────────────────────────────────────────
# dmgbuild writes the .DS_Store itself: no Finder AppleScript (it needs Apple Events, which some
# shells cannot send, and shipped other apps' DMGs without a layout).
echo "▶︎ build DMG"
DMG_BG="$STAGING_DIR/background.png"
"$ROOT/Scripts/make-dmg-background.swift" "$DMG_BG" >/dev/null

# dmgbuild and its two dependencies, installed once per requirements file into a private venv,
# every wheel checked against its pinned hash.
DMGBUILD_REQS="$ROOT/Scripts/dmgbuild-requirements.txt"
DMGBUILD_VENV="$ROOT/.dmgbuild-venv/$(shasum -a 256 "$DMGBUILD_REQS" | cut -c1-12)"
if [ ! -x "$DMGBUILD_VENV/bin/dmgbuild" ]; then
  echo "▶︎ installing dmgbuild (one-time)"
  rm -rf "$DMGBUILD_VENV"
  python3 -m venv "$DMGBUILD_VENV"
  "$DMGBUILD_VENV/bin/pip" install --quiet --disable-pip-version-check \
    --only-binary=:all: --require-hashes -r "$DMGBUILD_REQS"
fi

# hdiutil detach can fail with "resource busy". Retry, then force.
detach_retry() {
  local mnt="$1" i
  for i in 1 2 3 4 5; do
    if hdiutil detach "$mnt" -quiet; then
      return 0
    fi
    echo "  …hdiutil detach retry $i/5 ($mnt busy) in 2s" >&2
    sleep 2
  done
  hdiutil detach "$mnt" -force -quiet
}
# Detach any volume left mounted by an aborted previous run of this version.
for STALE in "/Volumes/$DMG_VOLNAME" "/Volumes/$DMG_VOLNAME "[0-9]*; do
  if [ -d "$STALE" ]; then
    echo "  …detaching stale volume $STALE" >&2
    detach_retry "$STALE"
  fi
done

rm -f "$DMG"
"$DMGBUILD_VENV/bin/dmgbuild" -s "$ROOT/Scripts/dmg-settings.py" \
  -D app="$STAGING" -D background="$DMG_BG" \
  "$DMG_VOLNAME" "$DMG" 2> >(grep -v "is deprecated" >&2) >/dev/null

# The layout is deterministic, so its absence is a bug.
CHECK_MOUNT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG" | awk -F '\t' 'END {print $NF}')"
LAYOUT_OK=1
for ITEM in .DS_Store .background.png Applications "$APP_NAME.app"; do
  [ -e "$CHECK_MOUNT/$ITEM" ] || { echo "✗ DMG is missing $ITEM" >&2; LAYOUT_OK=0; }
done
codesign --verify --deep --strict "$CHECK_MOUNT/$APP_NAME.app" || LAYOUT_OK=0
detach_retry "$CHECK_MOUNT"
[ "$LAYOUT_OK" = 1 ] || exit 1

# The DMG itself carries the Developer ID signature too (checked by spctl after stapling).
echo "▶︎ codesign the DMG"
for i in 1 2 3 4 5; do
  if codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"; then break; fi
  [ "$i" -lt 5 ] || { echo "✗ codesign of the DMG failed" >&2; exit 1; }
  echo "  …codesign retry $i/5 (timestamp server) in 5s" >&2
  sleep 5
done
codesign --verify --strict --verbose=1 "$DMG"
DMG_SIGNATURE="$(codesign -dvv "$DMG" 2>&1)"
grep -q "Authority=$SIGNING_IDENTITY" <<<"$DMG_SIGNATURE" \
  || { echo "✗ DMG not signed with $SIGNING_IDENTITY" >&2; exit 1; }

if [ "$DRY_RUN" = 1 ]; then
  SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
  echo
  echo "✅ Dry run passed up to notarization: $DMG ($SIZE)"
  echo "   Not done: notarization, staple, spctl, Sparkle signature, appcast.xml. Delete $OUT_DIR when done."
  exit 0
fi

# ── 7. Notarize: only "Accepted" for this DMG counts ───────────────────────────────────────────
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
✗ Notary profile "$NOTARY_PROFILE" not found.
  Create it once (interactive):
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "<your Apple ID>" --team-id "KFLACS69T9"
  The DMG was built and signed at: $DMG (NOT yet notarized).
EOF
  exit 1
fi
echo "▶︎ notarize (this takes a few minutes)"
# `submit --wait` exits 0 even when Apple returns "Invalid": read the status.
NOTARY_JSON="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
# Any parse problem yields empty fields, so it reaches the "not accepted" path below.
NOTARY_FIELDS="$(printf '%s' "$NOTARY_JSON" | python3 -I -c '
import sys, json
text = sys.stdin.read()
try:
    d = json.loads(text)
except ValueError:
    # Progress text reached stdout: keep the last single-line JSON object.
    try:
        lines = [l for l in text.splitlines() if l.lstrip().startswith("{")]
        d = json.loads(lines[-1]) if lines else {}
    except ValueError:
        d = {}
if not isinstance(d, dict):
    d = {}
print(d.get("id", ""), d.get("status", ""), sep="\t")')"
NOTARY_ID="$(printf '%s' "$NOTARY_FIELDS" | cut -f1)"
NOTARY_STATUS="$(printf '%s' "$NOTARY_FIELDS" | cut -f2)"
echo "  notarization $NOTARY_ID: $NOTARY_STATUS"
if [ "$NOTARY_STATUS" != "Accepted" ]; then
  echo "✗ notarization not accepted (status: ${NOTARY_STATUS:-unknown})" >&2
  if [ -n "$NOTARY_ID" ]; then
    xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  exit 1
fi

# ── 8. Staple, then check the shipped bytes independently (T5.3 L7) ────────────────────────────
echo "▶︎ staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "▶︎ Gatekeeper checks on the stapled DMG and the app inside it"
GATE_OK=1
DMG_SPCTL="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1)" || GATE_OK=0
echo "$DMG_SPCTL"
grep -q "source=Notarized Developer ID" <<<"$DMG_SPCTL" || GATE_OK=0
CHECK_MOUNT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG" | awk -F '\t' 'END {print $NF}')"
SPCTL_OUT="$(spctl -a -t exec -vv "$CHECK_MOUNT/$APP_NAME.app" 2>&1)" || GATE_OK=0
echo "$SPCTL_OUT"
grep -q "source=Notarized Developer ID" <<<"$SPCTL_OUT" || GATE_OK=0
codesign --verify --deep --strict --verbose=1 "$CHECK_MOUNT/$APP_NAME.app" || GATE_OK=0
check_sparkle_signatures "$CHECK_MOUNT/$APP_NAME.app" || GATE_OK=0
detach_retry "$CHECK_MOUNT"
[ "$GATE_OK" = 1 ] || { echo "✗ Gatekeeper or signature check failed on the stapled DMG" >&2; exit 1; }

# ── 9. Sparkle: EdDSA-sign the DMG and add its item to appcast.xml ─────────────────────────────
# One cache directory per version: bumping SPARKLE_VERSION fetches fresh tools.
SPARKLE_TOOLS="$ROOT/.sparkle-tools/$SPARKLE_VERSION"
if [ ! -x "$SPARKLE_TOOLS/bin/sign_update" ]; then
  echo "▶︎ fetching Sparkle $SPARKLE_VERSION tools (one-time)"
  SPARKLE_TARBALL="$STAGING_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$SPARKLE_TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  ACTUAL_SHA256="$(shasum -a 256 "$SPARKLE_TARBALL" | cut -d ' ' -f1)"
  if [ "$ACTUAL_SHA256" != "$SPARKLE_TARBALL_SHA256" ]; then
    echo "✗ Sparkle tarball checksum mismatch" >&2
    echo "  expected $SPARKLE_TARBALL_SHA256" >&2
    echo "  got      $ACTUAL_SHA256" >&2
    exit 1
  fi
  mkdir -p "$SPARKLE_TOOLS"
  tar -xJf "$SPARKLE_TARBALL" -C "$SPARKLE_TOOLS"
fi

echo "▶︎ EdDSA-signing the DMG for Sparkle (account $SPARKLE_ACCOUNT)"
# Emits: sparkle:edSignature="…" length="<bytes>"
SPARKLE_SIG_LINE="$("$SPARKLE_TOOLS/bin/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"

echo "▶︎ adding v$VERSION to appcast.xml (sparkle:version=$BUILD_NUMBER, shortVersionString=$VERSION)"
SIG_LINE="$SPARKLE_SIG_LINE" python3 -I -c '
import os, re, sys, email.utils, xml.etree.ElementTree as ET
path, version, build, min_os, repo, dmg_name, dmg = sys.argv[1:8]
SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SP)
attrs = dict(re.findall(r"(sparkle:edSignature|length)=\"([^\"]+)\"", os.environ["SIG_LINE"]))
if set(attrs) != {"sparkle:edSignature", "length"}:
    sys.exit("✗ unexpected sign_update output")
if int(attrs["length"]) != os.path.getsize(dmg):
    sys.exit("✗ sign_update length does not match the DMG size")
tree = ET.parse(path)
channel = tree.getroot().find("channel")
item = ET.Element("item")
ET.SubElement(item, "title").text = "v" + version
ET.SubElement(item, "pubDate").text = email.utils.formatdate(localtime=False, usegmt=True)
ET.SubElement(item, "{%s}version" % SP).text = build
ET.SubElement(item, "{%s}shortVersionString" % SP).text = version
ET.SubElement(item, "{%s}minimumSystemVersion" % SP).text = min_os
# Opened in the browser ("Version History"), never loaded into the Sparkle web view.
ET.SubElement(item, "{%s}fullReleaseNotesLink" % SP).text = "https://github.com/%s/releases/tag/v%s" % (repo, version)
ET.SubElement(item, "enclosure", {
    "url": "https://github.com/%s/releases/download/v%s/%s" % (repo, version, dmg_name),
    "type": "application/octet-stream",
    "{%s}edSignature" % SP: attrs["sparkle:edSignature"],
    "length": attrs["length"],
})
# Newest first, after the channel metadata.
children = list(channel)
first_item = next((i for i, c in enumerate(children) if c.tag == "item"), len(children))
channel.insert(first_item, item)
ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
ET.parse(path)   # still well-formed
' "$ROOT/appcast.xml" "$VERSION" "$BUILD_NUMBER" "$MIN_SYSTEM_VERSION" "$GITHUB_REPO" "$(basename "$DMG")" "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo
echo "✅ Built, signed, notarized, stapled and Sparkle-signed: $(basename "$DMG") ($SIZE)"
echo
echo "Built from commit $BUILT_SHA."
echo "Publish (the tag must match the appcast enclosure URL; the repository must be public):"
echo "  gh release create v$VERSION \"$DMG\" --repo $GITHUB_REPO --target $BUILT_SHA --title \"v$VERSION\" --notes-file \"$NOTES\""
echo "Then commit appcast.xml on a branch and merge it to main: installed copies read it from"
echo "  https://raw.githubusercontent.com/$GITHUB_REPO/main/appcast.xml"
