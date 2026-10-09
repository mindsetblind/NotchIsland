# NotchIsland

Интерактивный Dynamic Island для MacBook с вырезом (Swift + SwiftUI, без зависимостей).

- **Свёрнут** — выглядит как обычный вырез.
- **Играет музыка** (Spotify / Apple Music) — обложка слева от выреза, эквалайзер справа.
- **Наведение курсора** — плавно раскрывается: трек, прогресс, ⏮ ⏯ ⏭.
- **Плейлист Spotify** (кнопка ☰) — треки текущего плейлиста/альбома, выбор трека без открытия Spotify.
- **Подключение зарядки** — короткое уведомление с процентом заряда.
- **Правый клик** — Spotify Client ID, «Запускать при входе», «Выйти».

## Сборка

Требуется macOS 14+ и Xcode (или Command Line Tools).

```bash
./build.sh            # собрать NotchIsland.app в папке проекта
./build.sh --install  # собрать, установить в /Applications и запустить
```

При первом треке macOS попросит разрешить управление Музыкой/Spotify — нажми «Разрешить».

## Плейлист Spotify

Список треков берётся из Spotify Web API, поэтому нужен свой Client ID:

1. Создай приложение на [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard).
2. Redirect URI: `http://127.0.0.1:8973/callback`, API: Web API.
3. Правый клик по острову → «Spotify Client ID…» → вставь Client ID, затем нажми ☰ → «Войти в Spotify».

Client Secret не нужен (OAuth PKCE), токен хранится в Связке ключей.

Ограничения Spotify для приложений в режиме разработки:
- выбор трека в своих плейлистах и альбомах идёт через Web API и требует **Premium**;
- чужие и алгоритмические плейлисты Spotify читать не даёт — для них показывается «Далее в очереди», а выбор трека выполняется перелистыванием (next/previous) до нужного.

## Видео вместо обложки

Пока обложка грузится, можно показывать зацикленное видео: положи файл в `Resources/placeholder.mp4` (в git не попадает) и пересобери. Без файла — градиент с нотой.

Диагностика Spotify пишется в `~/Library/Logs/NotchIsland.log`.

## Структура

| Файл | Что внутри |
|---|---|
| `Sources/main.swift` | окно поверх строки меню, отслеживание курсора |
| `Sources/Model.swift` | состояния, размеры, пружинные анимации |
| `Sources/Services.swift` | текущий трек (AppleScript), батарея (IOKit) |
| `Sources/Views.swift` | форма выреза и весь интерфейс, эквалайзер на Core Animation |
| `Sources/SpotifyWeb.swift` | Spotify Web API: вход (PKCE), плейлист/альбом/очередь, воспроизведение |
| `Sources/PlaceholderVideo.swift` | зацикленное видео-заглушка вместо обложки |
| `Sources/LoginItem.swift` | автозапуск при входе |
