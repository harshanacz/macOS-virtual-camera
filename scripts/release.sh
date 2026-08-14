#!/bin/bash
#
# Builds, signs, notarizes and staples Fuzzcam for distribution.
#
# Notarization is not optional polish. macOS refuses to load a camera system
# extension unless the containing app passes Gatekeeper. This was verified
# empirically on macOS 26.6:
#
#   Apple Development signed  -> sysextd refuses (spctl: rejected)
#   Developer ID, unnotarized -> sysextd refuses (spctl: rejected,
#                                                 source=Unnotarized Developer ID)
#   Developer ID, notarized   -> the supported path, which is what this produces
#
# The only alternative is `systemextensionsctl developer on`, which requires
# disabling SIP. Do not do that on a machine you care about.
#
# One-time setup (needs an app-specific password from appleid.apple.com):
#
#   xcrun notarytool store-credentials fuzzcam-notary \
#     --apple-id "you@example.com" --team-id C37NWJLS6S --password "xxxx-xxxx-xxxx-xxxx"
#
# Usage:  ./scripts/release.sh [notary-profile-name]

set -euo pipefail

PROFILE="${1:-fuzzcam-notary}"
TEAM_ID="C37NWJLS6S"
APP_BUNDLE_ID="com.harshanacz.Fuzzcam"
EXT_BUNDLE_ID="com.harshanacz.Fuzzcam.Extension"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Fuzzcam.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Fuzzcam.app"
EXT="$APP/Contents/Library/SystemExtensions/FuzzcamExtension.systemextension"

cd "$ROOT"

# ---------------------------------------------------------------- preflight --
# Fail in two seconds rather than after a five-minute build.

echo "==> Preflight"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application.*$TEAM_ID"; then
    echo "ERROR: no 'Developer ID Application' certificate for team $TEAM_ID in the keychain." >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MISSING
ERROR: notarytool credentials '$PROFILE' are not configured.

Store them once with an app-specific password from https://appleid.apple.com:

    xcrun notarytool store-credentials $PROFILE \\
        --apple-id "your-apple-id@example.com" \\
        --team-id $TEAM_ID \\
        --password "xxxx-xxxx-xxxx-xxxx"

Then re-run this script.
MISSING
    exit 1
fi

echo "    Developer ID certificate: found"
echo "    notarytool profile '$PROFILE': found"

rm -rf "$BUILD"
mkdir -p "$BUILD"

# ------------------------------------------------------------------ archive --
# Archive with the project's normal automatic signing. Forcing
# CODE_SIGN_IDENTITY here fails with "conflicting provisioning settings" — the
# Developer ID identity is applied by the export step, which re-signs.

echo "==> Archiving"
xcodebuild archive \
    -project Fuzzcam.xcodeproj \
    -scheme Fuzzcam \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    2>&1 | grep -E "error:|warning:|ARCHIVE" | grep -v appintentsmetadata || true

[ -d "$ARCHIVE" ] || { echo "ERROR: archive failed" >&2; exit 1; }

# ------------------------------------------------------------------- export --

echo "==> Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates >/dev/null

[ -d "$APP" ] || { echo "ERROR: export produced no app" >&2; exit 1; }

# ------------------------------------------------------------------- verify --

echo "==> Verifying the bundle"
[ -d "$EXT" ] || { echo "ERROR: camera extension missing from the app bundle" >&2; exit 1; }

for bundle in "$APP" "$EXT"; do
    if ! codesign -dvvv "$bundle" 2>&1 | grep -q "Developer ID Application"; then
        echo "ERROR: $(basename "$bundle") is not Developer ID signed" >&2
        exit 1
    fi
done

# A system extension carrying get-task-allow is treated as a development build
# and will be refused.
if codesign -d --entitlements - --xml "$EXT" 2>/dev/null | grep -q "get-task-allow"; then
    echo "ERROR: extension is signed with get-task-allow" >&2
    exit 1
fi

codesign -v --deep --strict "$APP"
echo "    signature: valid, Developer ID, no get-task-allow"

# ---------------------------------------------------------------- notarize --

echo "==> Notarizing (a few minutes)"
ZIP="$BUILD/Fuzzcam.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# ------------------------------------------------------------------- assess --

echo "==> Gatekeeper assessment"
if spctl -a -vvv -t exec "$APP" 2>&1 | grep -q "accepted"; then
    echo "    accepted — this build can install its camera extension"
else
    echo "ERROR: still rejected by Gatekeeper; the extension will not load" >&2
    spctl -a -vvv -t exec "$APP" || true
    exit 1
fi

cat <<DONE

Done.  Install and activate:

    pkill -f 'Fuzzcam.app/Contents/MacOS/Fuzzcam' || true
    rm -rf /Applications/Fuzzcam.app
    cp -R "$APP" /Applications/
    open /Applications/Fuzzcam.app

macOS will ask you to approve the extension:

    System Settings > General > Login Items & Extensions > Camera Extensions
    -> enable Fuzzcam

Then confirm:

    systemextensionsctl list                              # expect [activated enabled]
    system_profiler SPCameraDataType | grep -A2 Fuzzcam   # expect the Fuzzcam device
DONE
