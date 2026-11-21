#!/bin/bash
# One step for a release. Run on the Mac:
#   "/Volumes/Backup/AppsBinsLibs/Eve App/GUI/scripts/release.sh"
# 1. Builds the Release app (same as Xcode Product → Archive → Distribute App → Custom → Copy App).
# 2. make-dmg.sh: privacy check, .dmg (with Read Me files), .zip, checksums, release notes with checksum.
# 3. Pushes main and the tags to GitHub.
# 4. Creates the GitHub release for the tag with the .dmg and .zip attached.
# Steps 3–4 need GitHub's command-line tool once:  brew install gh  then  gh auth login  and  gh auth setup-git
# Add --no-publish to stop after step 2.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
VERSION="$(grep -m1 'MARKETING_VERSION' EveCompanion.xcodeproj/project.pbxproj | sed 's/[^0-9.]//g')-beta"
TAG="v$VERSION"
NAME="EVE-Ore-to-ISK-$VERSION"
ARCHIVE="$HERE/build/$NAME.xcarchive"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "No git tag $TAG – tag the release commit first."; exit 1; }
[ -z "$(git status --porcelain)" ] || echo "Note: there are uncommitted changes – they are built but not pushed."

echo "1/4 Building EVE: Ore to ISK $VERSION (Release)…"
rm -rf "$ARCHIVE"
xcodebuild -project EveCompanion.xcodeproj -scheme EveCompanion -configuration Release \
  -archivePath "$ARCHIVE" archive -quiet
APP="$ARCHIVE/Products/Applications/EVE Ore to ISK.app"
[ -d "$APP" ] || { echo "The archive has no app at: $APP"; exit 1; }

echo "2/4 Packaging…"
bash "$HERE/scripts/make-dmg.sh" "$APP" "$VERSION"

if [ "${1:-}" = "--no-publish" ]; then echo "Stopped before publishing (--no-publish)."; exit 0; fi
if ! command -v gh >/dev/null; then
  echo "GitHub's 'gh' tool isn't installed, so push and make the release by hand:"
  echo "  git push origin main --tags, then a release for $TAG on GitHub with dist/$NAME.dmg and .zip"
  echo "  (or: brew install gh && gh auth login && gh auth setup-git, then run this again)"
  exit 0
fi

echo "3/4 Pushing main and tags…"
git push origin main --tags

echo "4/4 Creating the GitHub release $TAG…"
gh release create "$TAG" "dist/$NAME.dmg" "dist/$NAME.zip" "dist/$NAME.sha256" \
  --title "EVE: Ore to ISK $VERSION" --notes-file "dist/$NAME-release-notes.md" --prerelease
echo "Released: $(gh release view "$TAG" --json url -q .url)"
