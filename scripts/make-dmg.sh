#!/bin/bash
# Packages an exported "EVE Ore to ISK.app" as a drag-to-Applications .dmg, after checking that
# nothing private is inside it. Run on the Mac:   ./scripts/make-dmg.sh "/path/to/EVE Ore to ISK.app"
set -euo pipefail

APP="${1:?Give the path to the exported EVE Ore to ISK.app}"
VERSION="${2:-1.0-beta}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/dist"
NAME="EVE-Ore-to-ISK-$VERSION"

[ -d "$APP" ] || { echo "Not found: $APP"; exit 1; }

echo "Checking the app for anything private…"
BAD=$(find "$APP" \( -name ".env" -o -name "*.sqlite*" -o -name "*.xcuserstate" \) -print)
if [ -n "$BAD" ]; then echo "STOP – private files inside the app:"; echo "$BAD"; exit 1; fi
if grep -rIl -e "EVE_CLIENT_SECRET" -e "client_secret=" "$APP" >/dev/null 2>&1; then
  echo "STOP – the app mentions a client secret."; exit 1
fi
echo "  OK – no .env, databases or secrets."

mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/$NAME.dmg"
hdiutil create -volname "EVE Ore to ISK" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
( cd "$OUT" && shasum -a 256 "$NAME.dmg" | tee "$NAME.dmg.sha256" )
echo "Done: $OUT/$NAME.dmg"
