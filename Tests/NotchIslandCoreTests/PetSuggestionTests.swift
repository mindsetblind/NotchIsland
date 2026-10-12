import Foundation
import Testing
@testable import NotchIslandCore

struct PetSuggestionTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func countsTopLevelEntries() {
        let day: TimeInterval = 86400
        let stats = PetFolderStats(entries: [
            .init(name: "Снимок экрана 2026-10-01 в 10.00.png", modified: now, isDirectory: false),
            .init(name: "Screenshot 2026.png", modified: now, isDirectory: false),
            .init(name: "app.dmg", modified: now.addingTimeInterval(-10 * day), isDirectory: false),
            .init(name: "fresh.pkg", modified: now, isDirectory: false),
            .init(name: "old.pdf", modified: now.addingTimeInterval(-40 * day), isDirectory: false),
            .init(name: ".DS_Store", modified: now.addingTimeInterval(-90 * day), isDirectory: false),
        ], now: now)
        #expect(stats == PetFolderStats(files: 5, olderThanMonth: 1, screenshots: 2, oldInstallers: 1))
    }

    @Test func offersTheMostSpecificThing() {
        let s = PetSuggester()
        let downloads = PetFolderStats(files: 80, olderThanMonth: 50, oldInstallers: 4)
        #expect(s.next(now: now, downloads: downloads, desktop: nil) == .oldInstallers)
        #expect(s.next(now: now, downloads: PetFolderStats(olderThanMonth: 50), desktop: nil) == .tidyDownloads)
        #expect(s.next(now: now, downloads: PetFolderStats(olderThanMonth: 5), desktop: PetFolderStats(screenshots: 3)) == nil)
    }

    @Test func staysPolite() {
        var s = PetSuggester()
        let downloads = PetFolderStats(olderThanMonth: 50, oldInstallers: 4)
        s.markShown(.oldInstallers, at: now)
        // Nothing for 3 hours…
        #expect(s.next(now: now.addingTimeInterval(3600), downloads: downloads, desktop: nil) == nil)
        // …then something else; installers only again after a week.
        #expect(s.next(now: now.addingTimeInterval(4 * 3600), downloads: downloads, desktop: nil) == .tidyDownloads)
        #expect(s.next(now: now.addingTimeInterval(8 * 86400), downloads: downloads, desktop: nil) == .oldInstallers)
    }

    @Test func survivesSaving() throws {
        var s = PetSuggester()
        s.markShown(.desktopScreenshots, at: now)
        let back = try JSONDecoder().decode(PetSuggester.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
