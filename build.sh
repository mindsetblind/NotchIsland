#!/bin/zsh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=NotchIsland.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/NotchIsland $APP/Contents/MacOS/
cp Info.plist $APP/Contents/
codesign --force --sign - $APP
echo "Built $APP"

# ./build.sh --install  → copy to /Applications and relaunch
if [[ "$1" == "--install" ]]; then
    pkill -x NotchIsland || true
    rm -rf /Applications/$APP
    cp -R $APP /Applications/
    open /Applications/$APP
    echo "Installed to /Applications/$APP"
fi
