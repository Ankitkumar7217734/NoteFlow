#!/bin/bash
# Build a release .app bundle and package it into a styled .dmg with a
# white background, drag-to-install arrow, and Applications symlink.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.dmg-build"
APP_NAME="NoteFlow"
DMG_NAME="NoteFlow"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_FILE="$PROJECT_DIR/$DMG_NAME.dmg"
MOUNT_DIR="/Volumes/$DMG_NAME"

echo ">> Detaching any stale mount + cleaning previous build..."
hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
rm -rf "$BUILD_DIR" "$DMG_FILE"
mkdir -p "$BUILD_DIR"

echo ">> Building release binary..."
cd "$PROJECT_DIR"
swift build -c release --product NoteFlow

echo ">> Creating .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp ".build/release/NoteFlow" "$APP_BUNDLE/Contents/MacOS/NoteFlow"

# SwiftPM's Bundle.module looks next to the .app Contents folder, not inside
# Resources — see resource_bundle_accessor.swift in the build output.
if [ -d ".build/release/NoteFlow_NoteFlow.bundle" ]; then
    cp -R ".build/release/NoteFlow_NoteFlow.bundle" "$APP_BUNDLE/Contents/"
fi

echo ">> Generating AppIcon.icns..."
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
SOURCE_ICON="$PROJECT_DIR/Sources/NoteFlow/Resources/logo.png"

sips -z 16   16   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z 32   32   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z 64   64   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z 256  256  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z 512  512  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo ">> Writing Info.plist..."
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>NoteFlow</string>
    <key>CFBundleIconFile</key>               <string>AppIcon</string>
    <key>CFBundleIdentifier</key>             <string>com.noteflow.app</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>NoteFlow</string>
    <key>CFBundleDisplayName</key>            <string>NoteFlow</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>1.3</string>
    <key>CFBundleVersion</key>                <string>4</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>NSPrincipalClass</key>               <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.productivity</string>
    <key>NSQuitAlwaysKeepsWindows</key>       <false/>
</dict>
</plist>
PLIST

echo ">> Generating DMG background..."
BG_PNG="$BUILD_DIR/background.png"
swift "$PROJECT_DIR/scripts/make-background.swift" "$BG_PNG"

echo ">> Staging DMG contents..."
STAGE_DIR="$BUILD_DIR/dmg-stage"
mkdir -p "$STAGE_DIR/.background"
cp "$BG_PNG" "$STAGE_DIR/.background/background.png"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo ">> Creating read-write DMG..."
TEMP_DMG="$BUILD_DIR/temp.dmg"
hdiutil create -srcfolder "$STAGE_DIR" \
               -volname "$DMG_NAME" \
               -fs HFS+ \
               -fsargs "-c c=64,a=16,e=16" \
               -format UDRW \
               -size 200m \
               "$TEMP_DMG"

echo ">> Mounting and styling DMG..."
hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG"
sleep 3

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 800, 600}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "$APP_NAME.app" of container window to {160, 200}
        set position of item "Applications" of container window to {440, 200}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sleep 2
sync
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
hdiutil detach "$MOUNT_DIR"

echo ">> Compressing DMG..."
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_FILE"

echo ">> Cleaning up..."
rm -rf "$BUILD_DIR"

echo ""
echo "✓ DMG created: $DMG_FILE"
ls -lh "$DMG_FILE"
