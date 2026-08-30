#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
version=${1:-0.1.0}
build_root=$(mktemp -d)
trap 'rm -rf "$build_root"' EXIT

xcodebuild archive \
  -project Oatmeal.xcodeproj \
  -scheme Oatmeal \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$build_root/Oatmeal.xcarchive" \
  -derivedDataPath "$build_root/DerivedData" \
  -clonedSourcePackagesDirPath /tmp/oatmeal-packages \
  MARKETING_VERSION="$version" \
  CODE_SIGNING_ALLOWED=NO

mkdir "$build_root/dmg"
ditto "$build_root/Oatmeal.xcarchive/Products/Applications/Oatmeal.app" "$build_root/dmg/Oatmeal.app"
ln -s /Applications "$build_root/dmg/Applications"

if [[ -n ${DEVELOPER_ID_APPLICATION:-} ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$build_root/dmg/Oatmeal.app"
else
  codesign --force --deep --sign - "$build_root/dmg/Oatmeal.app"
fi

hdiutil create -volname Oatmeal -srcfolder "$build_root/dmg" -ov -format UDZO Oatmeal.dmg

if [[ -n ${DEVELOPER_ID_APPLICATION:-} && -n ${APPLE_ID:-} && -n ${APPLE_TEAM_ID:-} && -n ${APPLE_APP_PASSWORD:-} ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" Oatmeal.dmg
  xcrun notarytool submit Oatmeal.dmg \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple Oatmeal.dmg
fi

shasum -a 256 Oatmeal.dmg
