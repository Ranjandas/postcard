#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Postcard"
CONFIG="release"
APP_BUNDLE="${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_DIR=$(swift build -c "${CONFIG}" --show-bin-path)
BIN_PATH="${BIN_DIR}/${APP_NAME}"

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Copy every SwiftPM-generated resource bundle (the app's own Public assets,
# plus any privacy-manifest bundles from dependencies like swift-nio/swift-crypto).
find "${BIN_DIR}" -maxdepth 1 -name "*.bundle" -exec cp -R {} "${APP_BUNDLE}/Contents/Resources/" \;

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
fi

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Built ${APP_BUNDLE}. Run: open ${APP_BUNDLE}"
