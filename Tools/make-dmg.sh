#!/bin/bash
# Builds a Release ArtemisMac.app and packages it as a drag-to-Applications DMG.
# Uses only built-in tools (xcodebuild, codesign, hdiutil). Never installs anything:
# the DMG only contains a symlink to /Applications. See Tools/PACKAGING.md.
#
#   Tools/make-dmg.sh [--skip-build] [--clean] [--derived-data DIR] [--out DIR]
#
#   --skip-build        package the app already in DIR/Build/Products/Release
#   --clean             clean build (default: incremental)
#   --derived-data DIR  default: $ARTEMIS_SCRATCH/DerivedData-dmg.noindex
#   --out DIR           default: $ARTEMIS_SCRATCH/dist
#
# ARTEMIS_SCRATCH defaults to ~/Desktop/ClaudeScratch; build logs go to its logs/.
set -euo pipefail

APP_NAME=ArtemisMac
BUNDLE_ID=com.sforkoak.artemis.mac
TEAM_ID=CHD882B8G5
HELPER=ArtemisAWDLHelper
HELPER_PLIST=com.sforkoak.artemis.awdl-helper.plist
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${ARTEMIS_SCRATCH:-$HOME/Desktop/ClaudeScratch}"
# Outside a .noindex folder the build is re-registered with LaunchServices seconds after lsregister -u
DERIVED="$SCRATCH/DerivedData-dmg.noindex"
DIST="$SCRATCH/dist"
BUILD=1
CLEAN=

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) BUILD= ;;
        --clean) CLEAN=clean ;;
        --derived-data) DERIVED="$2"; shift ;;
        --out) DIST="$2"; shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

case "$DERIVED" in
    *.noindex|*.noindex/*) ;;
    *) echo "warning: $DERIVED isn't in a .noindex folder, so the build will likely be re-registered as an art:// handler" >&2 ;;
esac

mkdir -p "$DIST" "$SCRATCH/logs"
DIST="$(cd "$DIST" && pwd -P)"
case "$DIST/" in
    /Applications/*|/System/*|/Library/*) die "refusing to write into $DIST" ;;
esac

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
STAGE="$(mktemp -d "$DIST/.stage.XXXXXX")"
cleanup() {
    if [ -d "$STAGE/mnt" ]; then
        hdiutil detach -quiet "$STAGE/mnt" 2>/dev/null || hdiutil detach -quiet -force "$STAGE/mnt" 2>/dev/null || true
    fi
    rm -rf "$STAGE"
    # Never let a packaging build take over art:// links from the installed copy
    if [ -d "$APP" ]; then
        "$LSREGISTER" -u "$APP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Name the DMG after the commit it was built from
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    GIT_SHA="$GIT_SHA-dirty"
    echo "warning: the working tree has uncommitted changes; the DMG will be named *-dirty" >&2
fi

if [ -n "$BUILD" ]; then
    LOG="$SCRATCH/logs/make-dmg-$(date +%Y%m%d-%H%M%S).log"
    step "Building Release $APP_NAME.app (log: $LOG)"
    if ! xcodebuild -project "$ROOT/Moonlight.xcodeproj" -scheme "Moonlight for macOS" \
            -configuration Release -derivedDataPath "$DERIVED" -allowProvisioningUpdates \
            $CLEAN build > "$LOG" 2>&1; then
        grep -E 'error:|\*\* BUILD' "$LOG" | tail -20 >&2 || tail -20 "$LOG" >&2
        die "build failed; see $LOG"
    fi
fi
[ -d "$APP" ] || die "no app at $APP (build first, or drop --skip-build)"
"$LSREGISTER" -u "$APP" 2>/dev/null || true

step "Checking the app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || die "bundle ID is $(plist CFBundleIdentifier), expected $BUNDLE_ID"
[ "$(plist CFBundleExecutable)" = "$APP_NAME" ] || die "executable is $(plist CFBundleExecutable), expected $APP_NAME"
[ "$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")" = arm64 ] || die "$APP_NAME isn't arm64-only"
[ -x "$APP/Contents/MacOS/$HELPER" ] || die "the AWDL helper is missing"
DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/$HELPER_PLIST"
[ -f "$DAEMON_PLIST" ] || die "the helper's launchd plist is missing"
[ "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' "$DAEMON_PLIST")" = "$BUNDLE_ID" ] \
    || die "the helper plist isn't associated with $BUNDLE_ID"
codesign --verify --deep --strict "$APP" || die "the app's signature doesn't verify"
for code in "$APP" "$APP/Contents/MacOS/$HELPER" "$APP"/Contents/Frameworks/*.framework; do
    info="$(codesign -dvv "$code" 2>&1)"
    echo "$info" | grep -qx "TeamIdentifier=$TEAM_ID" || die "$code isn't signed by team $TEAM_ID"
    echo "$info" | grep -q 'flags=.*(runtime)' || die "$code doesn't use the hardened runtime"
done
VERSION="$(plist CFBundleShortVersionString)"
BUILD_NUMBER="$(plist CFBundleVersion)"
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "    $APP_NAME $VERSION ($BUILD_NUMBER), $GIT_SHA, signed by $SIGNER"

step "Staging"
mkdir "$STAGE/root"
# Leave out local metadata (provenance, quarantine) that means nothing on another Mac
ditto --norsrc --noextattr --noqtn --noacl "$APP" "$STAGE/root/$APP_NAME.app"
ln -s /Applications "$STAGE/root/Applications"

DMG="$DIST/$APP_NAME-$VERSION-$BUILD_NUMBER-$GIT_SHA.dmg"
step "Creating $DMG"
hdiutil create -quiet -ov -volname "$APP_NAME" -srcfolder "$STAGE/root" -fs HFS+ -format ULFO "$DMG"
# Only a Developer ID signature on the DMG helps Gatekeeper. With Apple Development it's
# rejected like the app, so leave the DMG unsigned and let the check happen once, on the app.
case "$SIGNER" in
    "Developer ID Application:"*)
        # Sign with the exact certificate that signed the app
        (cd "$STAGE" && codesign -d --extract-certificates=cert "$APP" 2>/dev/null)
        codesign --force --timestamp --sign "$(shasum -a 1 "$STAGE/cert0" | cut -d' ' -f1)" "$DMG"
        rm -f "$STAGE"/cert*
        codesign --verify "$DMG" || die "the DMG's signature doesn't verify"
        ;;
esac

step "Verifying the DMG"
hdiutil verify -quiet "$DMG" || die "hdiutil verify failed"
mkdir "$STAGE/mnt"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$STAGE/mnt" "$DMG"
codesign --verify --deep --strict "$STAGE/mnt/$APP_NAME.app" || die "the app in the DMG doesn't verify"
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
[ "$(cdhash "$STAGE/mnt/$APP_NAME.app")" = "$(cdhash "$APP")" ] || die "the app in the DMG differs from the build"
[ "$(readlink "$STAGE/mnt/Applications")" = /Applications ] || die "the Applications link is wrong"
hdiutil detach -quiet "$STAGE/mnt"
rmdir "$STAGE/mnt"

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

# What Gatekeeper will say on a Mac where the DMG arrives quarantined (downloaded, AirDropped)
step "Gatekeeper preview (expected: rejected, because the app isn't Developer ID signed and notarized)"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/    /' || true

echo
echo "$DMG"
echo "    $(stat -f %z "$DMG" | awk '{printf "%.1f MB", $1 / 1e6}')"
