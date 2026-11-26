#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/SC Pro.app"
ZIP="$ROOT/build/ShotShelf.zip"
PROFILE="${NOTARY_PROFILE:-shotshelf}"

if [[ ! -d "$APP" ]]; then
  echo "Build SC Pro first: ./build.sh" >&2
  exit 1
fi

ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "Notarized $ZIP"
