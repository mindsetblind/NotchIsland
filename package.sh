#!/bin/zsh
# Builds a DMG to share NotchIsland with someone else: universal (Apple Silicon + Intel),
# without your personal placeholder picture/video, with a "how to open" note.
#   ./package.sh            → dist/NotchIsland.dmg
set -e
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN=$(swift build -c release $ARCHS --show-bin-path)

STAGE=$(mktemp -d)
APP=$STAGE/NotchIsland.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp $BIN/NotchIsland $BIN/notchisland-hook $BIN/notchisland-cli $APP/Contents/MacOS/
ditto $BIN/Sparkle.framework $APP/Contents/Frameworks/Sparkle.framework
rm -rf $APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices $APP/Contents/Frameworks/Sparkle.framework/XPCServices
cp Info.plist $APP/Contents/
cp Icon/AppIcon.icns $APP/Contents/Resources/
# No Resources/placeholder.* here: that's your own media. Settings let the recipient pick theirs.

# Ad-hoc signature: without a paid Developer ID the app can't be notarized anyway, and a personal
# Apple Development certificate means nothing on another Mac.
codesign --force --deep --sign - $APP

ln -s /Applications $STAGE/Applications
cat > "$STAGE/Как открыть.txt" <<'TXT'
NotchIsland — Dynamic Island для MacBook с вырезом (macOS 14 и новее, Apple Silicon и Intel).

1. Перетащи NotchIsland в папку «Программы».
2. Открой его. macOS скажет, что не может проверить разработчика, — это нормально:
   приложение не нотаризовано в Apple.
   Открой Системные настройки → Конфиденциальность и безопасность, пролистай вниз
   и нажми «Всё равно открыть» напротив NotchIsland. Подтверди паролем.
   Если пишет «Не удаётся открыть программу» (только кнопка OK) — выполни в Терминале
   xattr -dr com.apple.quarantine /Applications/NotchIsland.app
   и открой снова. Не помогло — запусти /Applications/NotchIsland.app/Contents/MacOS/NotchIsland
   в Терминале и пришли автору текст ошибки, версию macOS и процессор.
3. Остров появится у выреза. Настройки — правый клик по острову → «Настройки…»
   (или открой остров кликом и нажми шестерёнку справа).

По желанию:
• Spotify: плейлисты, выбор трека и музыка через pet — нужен свой Client ID: создай приложение
  на developer.spotify.com с Redirect URI http://127.0.0.1:8973/callback, вставь Client ID
  в настройках (вкладка «Музыка») и войди. Без этого текущий трек и кнопки управления всё равно работают.
• Pet (⌥⇧Space) думает через Claude Code: установи его (claude.com/claude-code) и один раз
  выполни в Терминале «claude auth login». Простые команды («пауза», «найди …») работают и без него.
• macOS спросит доступы (Автоматизация для Spotify/Музыки, микрофон для голоса pet и т. д.) —
  только когда соответствующая функция понадобится.
TXT

mkdir -p dist
rm -f dist/NotchIsland.dmg
hdiutil create -volname NotchIsland -srcfolder $STAGE -fs HFS+ -format UDZO -ov dist/NotchIsland.dmg >/dev/null
# The app alone, for release.sh (zip for Sparkle updates).
rm -rf dist/NotchIsland.app
ditto $APP dist/NotchIsland.app
rm -rf $STAGE
echo "dist/NotchIsland.dmg ($(du -h dist/NotchIsland.dmg | cut -f1))"
