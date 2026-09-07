#!/usr/bin/env bash

set -e

APP_NAME="QuotaMew"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
  echo "Usage:"
  echo "  ./script/create-dmg.sh <version>"
  exit 1
fi

APP_PATH="release/v${VERSION}/${APP_NAME}.app"

DMG_ROOT="dist/dmg"
TEMP_DMG="dist/${APP_NAME}-temp.dmg"
FINAL_DMG="dist/${APP_NAME}-v${VERSION}.dmg"
SHA_FILE="${FINAL_DMG}.sha256"

VOLUME_NAME="${APP_NAME}"
MOUNT_PATH="/Volumes/${VOLUME_NAME}"

echo "==> Version: v${VERSION}"
echo "==> App path: ${APP_PATH}"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: App not found:"
  echo "  $APP_PATH"
  exit 1
fi

echo "==> Cleaning old build files..."

rm -rf "$DMG_ROOT"
rm -f "$TEMP_DMG"
rm -f "$FINAL_DMG"
rm -f "$SHA_FILE"

mkdir -p "$DMG_ROOT"

echo "==> Copying app..."

ditto \
  "$APP_PATH" \
  "$DMG_ROOT/${APP_NAME}.app"

echo "==> Creating Applications shortcut..."

ln -s /Applications "$DMG_ROOT/Applications"

echo "==> Creating writable DMG..."

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDRW \
  "$TEMP_DMG"

echo "==> Mounting DMG..."

hdiutil attach \
  "$TEMP_DMG" \
  -readwrite \
  -noverify \
  -noautoopen

echo "==> Configuring Finder layout..."

osascript <<EOF
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open

        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false

        set bounds of container window to {100, 100, 760, 500}

        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96

        set position of item "${APP_NAME}.app" of container window to {170, 170}
        set position of item "Applications" of container window to {490, 170}

        close
        open

        update without registering applications

        delay 2
    end tell
end tell
EOF

echo "==> Saving Finder layout..."

sync
sleep 2

echo "==> Detaching DMG..."

hdiutil detach "$MOUNT_PATH"

echo "==> Compressing DMG..."

hdiutil convert \
  "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_DMG"

echo "==> Verifying DMG..."

hdiutil verify "$FINAL_DMG"

echo "==> Creating SHA-256..."

shasum -a 256 "$FINAL_DMG" > "$SHA_FILE"

echo "==> Removing temporary DMG..."

rm -f "$TEMP_DMG"

echo
echo "======================================"
echo "${APP_NAME} DMG complete"
echo "======================================"
echo
echo "Version:"
echo "  v${VERSION}"
echo
echo "DMG:"
echo "  ${FINAL_DMG}"
echo
echo "SHA-256:"
cat "$SHA_FILE"
echo
