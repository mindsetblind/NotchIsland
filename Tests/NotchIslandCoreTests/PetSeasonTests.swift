import Testing
@testable import NotchIslandCore

struct PetSeasonTests {
    @Test func hats() {
        #expect(PetSeasonHat.on(month: 10, day: 24) == nil)
        #expect(PetSeasonHat.on(month: 10, day: 31) == .witch)
        #expect(PetSeasonHat.on(month: 11, day: 1) == .witch)
        #expect(PetSeasonHat.on(month: 11, day: 2) == nil)
        #expect(PetSeasonHat.on(month: 12, day: 5) == .beanie)
        #expect(PetSeasonHat.on(month: 12, day: 24) == .santa)
        #expect(PetSeasonHat.on(month: 1, day: 10) == .santa)
        #expect(PetSeasonHat.on(month: 1, day: 11) == .beanie)
        #expect(PetSeasonHat.on(month: 2, day: 28) == .beanie)
        #expect(PetSeasonHat.on(month: 3, day: 1) == nil)
    }
}
