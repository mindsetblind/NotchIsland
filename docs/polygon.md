# Polygon

Polygon — планировщик (iPhone + Mac). Mac-версия сообщает острову о дне через тот же локальный
сокет, что и Developer Mode (`~/Library/Application Support/NotchIsland/claude.sock`), одной строкой JSON:

```json
{"v":1,"type":"polygon","event":"done","title":"Сдать лабу","all_three":false}
{"v":1,"type":"polygon","event":"soon","title":"Зал","minutes":10}
```

- `done` — задача сделана: pet у выреза радуется, а если сделаны все три главные задачи дня — танцует.
  Короткое уведомление «Готово».
- `soon` — событие из недельного расписания Polygon начинается через `minutes` минут: мягкое
  напоминание и взгляд pet. События «Календаря» остров и так показывает сам — Polygon их не дублирует.

Выключается переключателем «Polygon» в Настройках → уведомления. Как и всё, что приходит в сокет,
события только показываются: остров ничего не запускает и не открывает. Формат проверяется
`PolygonEventParser` (NotchIslandCore, тесты — `PolygonEventTests`).
