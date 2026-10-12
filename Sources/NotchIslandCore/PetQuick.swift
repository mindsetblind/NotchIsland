import Foundation

/// Requests simple enough to handle without asking a model: they run instantly.
/// Anything vague ("что-нибудь спокойное", "вчерашние скриншоты") returns nil and goes to Claude.
public enum PetQuickIntent: Equatable, Sendable {
    public enum Media: Equatable, Sendable { case pause, resume, next, previous }

    case media(Media)
    /// "включи Radiohead": a concrete name; `type` when the user said what it is ("альбом …").
    case play(String, type: PetMusic.Kind?)
    /// "найди договор": a file name to look up with Spotlight.
    case find(String)

    private static let media: [String: Media] = [
        "пауза": .pause, "стоп": .pause, "останови": .pause, "поставь на паузу": .pause, "выключи музыку": .pause,
        "pause": .pause, "stop": .pause,
        "продолжи": .resume, "продолжай": .resume, "играй": .resume, "сними с паузы": .resume,
        "resume": .resume,
        "дальше": .next, "следующий": .next, "следующая": .next, "следующую": .next, "следующий трек": .next,
        "скип": .next, "пропусти": .next, "next": .next, "skip": .next,
        "назад": .previous, "предыдущий": .previous, "предыдущая": .previous, "предыдущую": .previous,
        "предыдущий трек": .previous, "previous": .previous, "back": .previous,
    ]

    private static let playVerbs = ["включи ", "поставь ", "запусти ", "врубай ", "вруби ", "play "]
    private static let findVerbs = ["найди ", "найти ", "где лежит ", "где ", "find "]

    private static let typeWords: [(String, PetMusic.Kind)] = [
        ("песню ", .track), ("трек ", .track), ("альбом ", .album), ("плейлист ", .playlist),
        ("исполнителя ", .artist), ("группу ", .artist),
    ]

    /// Words that make a music request a matter of taste — Claude decides.
    private static let vagueMusic = [
        "что-нибудь", "что нибудь", "что-то", "что то", "чего-нибудь", "какую-нибудь", "какой-нибудь",
        "музык", "под ", "для ", "похож", "типа", "настроени", "спокойн", "весёл", "весел", "грустн",
        "бодр", "энергичн", "расслаб", "фонов", "микс", "подборк", "случайн", "новинк", "чтобы",
    ]

    /// Words that make a file search more than a name lookup.
    private static let vagueFind = [
        "вчера", "сегодня", "недел", "последн", "все ", "всё ", "больш", "скачанн", "скриншот", "похож",
        "который", "которые", "где-то", "что-то", "с ", "без ", "до ", "после ",
    ]

    public static func parse(_ raw: String) -> PetQuickIntent? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".!?,".contains(last) { text.removeLast() }
        guard !text.isEmpty, !text.contains("@") else { return nil }

        if let m = media[text] { return .media(m) }

        if let verb = playVerbs.first(where: text.hasPrefix) {
            var rest = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            var type: PetMusic.Kind?
            if let (word, kind) = typeWords.first(where: { rest.hasPrefix($0.0) }) {
                rest = String(rest.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
                type = kind
            }
            guard !rest.isEmpty, rest.split(separator: " ").count <= 6,
                  !vagueMusic.contains(where: { (rest + " ").contains($0) })
            else { return nil }
            // Keep the user's spelling (artist names), only drop the verb.
            let original = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return .play(String(original.suffix(rest.count)), type: type)
        }

        if let verb = findVerbs.first(where: text.hasPrefix) {
            var rest = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            for word in ["файл ", "файлы ", "документ ", "папку ", "мой ", "мою ", "мои "] where rest.hasPrefix(word) {
                rest = String(rest.dropFirst(word.count))
            }
            let padded = " " + rest + " "
            guard !rest.isEmpty, rest.split(separator: " ").count <= 4,
                  !vagueFind.contains(where: { padded.contains($0.hasSuffix(" ") ? " " + $0 : $0) })
            else { return nil }
            return .find(rest)
        }
        return nil
    }
}
