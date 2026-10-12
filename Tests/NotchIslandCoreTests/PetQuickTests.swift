import Testing
@testable import NotchIslandCore

struct PetQuickTests {
    @Test func mediaCommands() {
        #expect(PetQuickIntent.parse("Пауза") == .media(.pause))
        #expect(PetQuickIntent.parse("дальше!") == .media(.next))
        #expect(PetQuickIntent.parse("предыдущий трек") == .media(.previous))
        #expect(PetQuickIntent.parse("продолжи") == .media(.resume))
    }

    @Test func concreteNamesPlayInstantly() {
        #expect(PetQuickIntent.parse("включи Radiohead") == .play("Radiohead", type: nil))
        #expect(PetQuickIntent.parse("Поставь альбом In Rainbows.") == .play("In Rainbows", type: .album))
        #expect(PetQuickIntent.parse("включи песню Bohemian Rhapsody") == .play("Bohemian Rhapsody", type: .track))
        #expect(PetQuickIntent.parse("включи любимые") == .play("любимые", type: nil))
    }

    @Test func tasteGoesToClaude() {
        #expect(PetQuickIntent.parse("включи что-нибудь спокойное") == nil)
        #expect(PetQuickIntent.parse("поставь музыку для работы") == nil)
        #expect(PetQuickIntent.parse("включи что-то похожее на Radiohead") == nil)
        #expect(PetQuickIntent.parse("включи из @Для бега") == nil)
    }

    @Test func fileLookups() {
        #expect(PetQuickIntent.parse("найди договор аренды") == .find("договор аренды"))
        #expect(PetQuickIntent.parse("где файл резюме?") == .find("резюме"))
        #expect(PetQuickIntent.parse("найди вчерашние скриншоты") == nil)
        #expect(PetQuickIntent.parse("найди все pdf больше 10 мб") == nil)
        #expect(PetQuickIntent.parse("разложи загрузки по папкам") == nil)
    }
}
