#!/bin/bash
# Packages an exported "EVE Ore to ISK.app" as a drag-to-Applications .dmg and a .zip, after checking that
# nothing private is inside it. Run on the Mac:   ./scripts/make-dmg.sh "/path/to/EVE Ore to ISK.app"
set -euo pipefail

APP="${1:?Give the path to the exported EVE Ore to ISK.app}"
VERSION="${2:-1.4-beta}"
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
# The read-me files go in the .dmg next to the app.
mkdir -p "$STAGE/Read Me"
for f in README.md RELEASE_NOTES.md CHANGELOG.md LICENSE; do
  [ -f "$HERE/$f" ] && cp "$HERE/$f" "$STAGE/Read Me/"
done
rm -f "$OUT/$NAME.dmg"
hdiutil create -volname "EVE Ore to ISK" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
# The same app as a .zip too (ditto keeps the code signature intact).
rm -f "$OUT/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"
( cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" | tee "$NAME.sha256" )
# A copy of the release notes with the .dmg checksum filled in, ready to paste into GitHub.
SHA=$(shasum -a 256 "$OUT/$NAME.dmg" | cut -d' ' -f1)
sed "s/SHA256_HERE/$SHA/" "$HERE/RELEASE_NOTES.md" > "$OUT/$NAME-release-notes.md"
echo "Done:"
echo "  $OUT/$NAME.dmg"
echo "  $OUT/$NAME.zip"
echo "  $OUT/$NAME-release-notes.md  (paste into the GitHub release)"
[ -t 1 ] && [ -z "${NO_OPEN:-}" ] && open "$OUT" || true
