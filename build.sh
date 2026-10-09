#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=NotchIsland.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/NotchIsland $APP/Contents/MacOS/
cp Info.plist $APP/Contents/
# Optional looping video shown while artwork loads (not in git — put your own file there)
[[ -f Resources/placeholder.mp4 ]] && cp Resources/placeholder.mp4 $APP/Contents/Resources/
# Sign with a stable identity so macOS keeps granted permissions (Automation, Bluetooth, Keychain)
# across rebuilds. Override with SIGN_IDENTITY=...; falls back to ad-hoc signing if none is found.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application|NotchIsland/ {print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" $APP
    echo "Signed with identity $IDENTITY"
else
    codesign --force --sign - $APP
    echo "Signed ad-hoc (permissions may be asked again after each rebuild)"
fi
echo "Built $APP"

# ./build.sh --install  → copy to /Applications and relaunch
if [[ "$1" == "--install" ]]; then
    pkill -x NotchIsland || true
    while pgrep -x NotchIsland >/dev/null; do sleep 0.1; done   # wait until it has really quit
    rm -rf /Applications/$APP
    cp -R $APP /Applications/
    open /Applications/$APP
    echo "Installed to /Applications/$APP"
fi
