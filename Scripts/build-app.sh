#!/usr/bin/env bash
#
# Assembles AgentPet.app from the SwiftPM build products.
#
# SwiftPM produces bare executables with no bundle, so the Info.plist, the
# icon, and the shim's placement beside the app binary are all put together
# here. The shim sits next to the app executable because that is where the app
# looks for it, and where the generated hook commands point.

set -euo pipefail

CONFIGURATION="${CONFIGURATION:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-com.dncore.agentpet}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP="$ROOT/build/AgentPet.app"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product AgentPet
swift build -c "$CONFIGURATION" --product agentpet-hook

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 0755 "$BUILD_DIR/AgentPet"       "$APP/Contents/MacOS/AgentPet"
# The shim goes beside the app binary: the hook commands the runtime writes
# point at this exact path.
install -m 0755 "$BUILD_DIR/agentpet-hook"  "$APP/Contents/MacOS/agentpet-hook"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    install -m 0644 "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    no icon found; run Scripts/generate-icon.swift to make one" >&2
fi

# The menu bar icon: a template image, so AppKit can invert it for dark menu
# bars and highlights. Both scales, or Retina displays get a blurry one.
if [ -f "$ROOT/Resources/StatusIcon.png" ]; then
    install -m 0644 "$ROOT/Resources/StatusIcon.png"    "$APP/Contents/Resources/StatusIcon.png"
    install -m 0644 "$ROOT/Resources/StatusIcon@2x.png" "$APP/Contents/Resources/StatusIcon@2x.png"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>          <string>en</string>
    <key>CFBundleExecutable</key>                 <string>AgentPet</string>
    <key>CFBundleIconFile</key>                   <string>AppIcon</string>
    <key>CFBundleIdentifier</key>                 <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
    <key>CFBundleName</key>                       <string>Agent Pet Runtime</string>
    <key>NSHumanReadableCopyright</key>           <string>MIT licensed. Copyright (c) 2026 dncore.</string>
    <key>CFBundleDisplayName</key>                <string>Agent Pet Runtime</string>
    <key>CFBundlePackageType</key>                <string>APPL</string>
    <key>CFBundleShortVersionString</key>         <string>${VERSION}</string>
    <key>CFBundleVersion</key>                    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>             <string>14.0</string>
    <!-- A pet has no dock presence and no documents. This is what makes it an
         accessory app: menu bar only. -->
    <key>LSUIElement</key>                        <true/>
    <key>NSHighResolutionCapable</key>            <true/>
    <key>NSSupportsAutomaticTermination</key>     <false/>
    <key>NSSupportsSuddenTermination</key>        <false/>
    <!-- Shown in the Accessibility prompt, if a future adapter asks for it. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Agent Pet Runtime uses Apple Events only if an agent adapter needs to focus a terminal window.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for local use and for the app to keep a stable
# identity across launches, which matters because SMAppService registers it by
# bundle identifier. A distribution build should be signed and notarised with a
# Developer ID instead.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" 2>/dev/null \
        && echo "    ad-hoc signed" \
        || echo "    not signed (codesign failed; the app still runs locally)"
fi

echo "==> Done"
echo "    $APP"
du -sh "$APP" | sed 's/^/    /'
