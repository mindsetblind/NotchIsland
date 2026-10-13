#!/bin/zsh
# Publishes a new version: friends' NotchIsland finds it within a day and updates itself (Sparkle).
#   ./release.sh 1.2 "Кот теперь …"     → bumps the version, builds, signs, commits, tags, pushes,
#                                         and creates a GitHub release with zip + dmg + appcast.xml
#   ./release.sh 1.2 "…" --dry          → everything up to dist/, nothing committed or published
# The update signing key lives in your login Keychain (Sparkle's generate_keys); never commit it.
set -e
cd "$(dirname "$0")"
VERSION=$1
NOTES=${2:-"Исправления и улучшения."}
DRY=${3:-}
[[ -z "$VERSION" ]] && { echo "usage: ./release.sh <version> [notes] [--dry]"; exit 1; }
if [[ "$DRY" != "--dry" ]]; then
    git diff --quiet && git diff --cached --quiet || { echo "Сначала закоммить изменения."; exit 1; }
    git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Версия $VERSION уже выпущена."; exit 1; }
fi

REPO=$(git remote get-url origin | sed -E 's#.*github.com[:/](.*)\.git$#\1#; s#.*github.com[:/](.*)$#\1#')
PB=/usr/libexec/PlistBuddy
OLD_VERSION=$($PB -c "Print CFBundleShortVersionString" Info.plist)
OLD_BUILD=$($PB -c "Print CFBundleVersion" Info.plist)
BUILD=$(( OLD_BUILD + 1 ))
$PB -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" Info.plist

./package.sh
ZIP=dist/NotchIsland-$VERSION.zip
rm -f $ZIP
ditto -c -k --sequesterRsrc --keepParent dist/NotchIsland.app $ZIP
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update $ZIP)   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$VERSION/NotchIsland-$VERSION.zip"
DATE=$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NotchIsland</title>
    <item>
      <title>NotchIsland $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>${NOTES//$'\n'/<br>}</p>]]></description>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
echo "Готово в dist/: $ZIP, NotchIsland.dmg, appcast.xml (версия $VERSION, сборка $BUILD)"

if [[ "$DRY" == "--dry" ]]; then
    # A dry run doesn't keep the version bump.
    $PB -c "Set CFBundleShortVersionString $OLD_VERSION" -c "Set CFBundleVersion $OLD_BUILD" Info.plist
    exit 0
fi
git commit -q -m "Release $VERSION" Info.plist
git tag "v$VERSION"
git push -q && git push -q origin "v$VERSION"
gh release create "v$VERSION" "$ZIP" dist/NotchIsland.dmg dist/appcast.xml -R "$REPO" \
    --title "NotchIsland $VERSION" --notes "$NOTES" --latest
echo "Выпущено: https://github.com/$REPO/releases/tag/v$VERSION"
