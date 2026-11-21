#!/bin/bash
# Builds the release app and packages it, in one go. Run on the Mac from anywhere:
#   "/Volumes/Backup/AppsBinsLibs/Eve App/GUI/scripts/release.sh"
# Does the same as Xcode's Product → Archive → Distribute App → Custom → Copy App, then make-dmg.sh.
# Result in GUI/dist/: the .dmg, the .zip, checksums and the release notes with the checksum filled in.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(grep -m1 'MARKETING_VERSION' "$HERE/EveCompanion.xcodeproj/project.pbxproj" | sed 's/[^0-9.]//g')-beta"
ARCHIVE="$HERE/build/EVE-Ore-to-ISK-$VERSION.xcarchive"

echo "Building EVE: Ore to ISK $VERSION (Release)…"
rm -rf "$ARCHIVE"
xcodebuild -project "$HERE/EveCompanion.xcodeproj" -scheme EveCompanion -configuration Release \
  -archivePath "$ARCHIVE" archive -quiet

APP="$ARCHIVE/Products/Applications/EVE Ore to ISK.app"
[ -d "$APP" ] || { echo "The archive has no app at: $APP"; exit 1; }
echo "  Built: $APP"

"$HERE/scripts/make-dmg.sh" "$APP" "$VERSION"
