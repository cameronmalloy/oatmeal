#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
test -f Oatmeal.dmg
hdiutil verify Oatmeal.dmg >/dev/null
ruby -c Casks/oatmeal.rb >/dev/null

mount_point=$(mktemp -d)
trap 'hdiutil detach "$mount_point" >/dev/null 2>&1 || true; rmdir "$mount_point" 2>/dev/null || true' EXIT
hdiutil attach Oatmeal.dmg -nobrowse -mountpoint "$mount_point" >/dev/null
test -d "$mount_point/Oatmeal.app"
codesign --verify --deep --strict "$mount_point/Oatmeal.app"

"$mount_point/Oatmeal.app/Contents/MacOS/Oatmeal" --ui-testing >/dev/null 2>&1 &
app_pid=$!
sleep 2
kill -0 "$app_pid"
kill "$app_pid"
wait "$app_pid" 2>/dev/null || true

echo "Oatmeal.dmg passed release smoke checks."
