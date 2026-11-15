import NotchIslandCore
import SwiftUI

enum PetMood: Equatable {
    case idle        // calm, blinks now and then
    case working     // eyes dart left and right
    case attention   // wide eyes, small hop — needs you
    case happy       // ^ ^ eyes, a little jump
    case sleeping    // closed eyes, slow breathing
    case dancing     // music is playing: the eyes bounce like equalizer bars
    case hungry      // a file is being dragged: mouth open, waiting for a treat
    case gaping      // the file is right above the shelf: mouth wide open
    case munching    // a file landed on the shelf: chomp chomp, cheeks fill up
    case full        // files sit on the shelf: puffed cheeks, the odd chew
    case scared      // battery almost empty: shrinks and trembles
    case sad         // a device left, a build failed: droopy ears and eyes
    case waking      // the Mac woke up: a yawn and a stretch
    case listening   // the assistant hears you speak
    case thinking    // the assistant is working out a plan
    case presenting  // the assistant has a plan to show
    case failed      // a build failed: a glitch, then sad

    /// The cat has no animations of its own for the newer moods.
    var catFallback: PetMood {
        switch self {
        case .listening, .presenting: return .attention
        case .thinking: return .working
        case .failed: return .sad
        default: return self
        }
    }
}

/// Things the cat wears depending on what's going on (see IslandModel.petAccessories).
enum CatAccessory: String, Hashable, CaseIterable {
    case glasses      // a build/test is running or Claude Code is working
    case nightcap     // asleep
    case witchHat, santaHat, beanie   // seasonal
}

/// The pet's face at a fixed size (agent rows, cards, peeks): the same pet as `PetView`,
/// fitted to `size` points of height. In snapshot mode (ImageRenderer can't draw NSViews) a still
/// image of the pet in that mood is shown instead.
struct PetFace: View {
    let mood: PetMood
    var size: CGFloat = 18
    var gaze: CGFloat? = nil

    var body: some View {
        PetAvatar(mood: mood, catK: size / 34, gaze: gaze, accessories: [], extras: PetExtras())
            .frame(width: size * 1.6, height: size)
    }
}

/// What the icosahedron shows besides the mood (the cat ignores it).
struct PetExtras {
    var progress: Double? = nil
    var agents = 0
    /// Assemble from flying faces when it first appears.
    var entrance = false
    /// The pet that always sits by the notch: may unfold now and then after a long idle stretch.
    var easterEgg = false
    var motif: IcosaMotif = .none
}

/// The pet in the chosen look (Settings → Пет): the icosahedron or the cat.
struct PetAvatar: View {
    @ObservedObject private var settings = AppSettings.shared
    let mood: PetMood
    let catK: CGFloat
    var gaze: CGFloat?
    var accessories: Set<CatAccessory>
    var extras: PetExtras

    var body: some View {
        if settings.petStyle == PetStyle.cat.rawValue {
            CatView(mood: mood.catFallback, pointsPerCSSPixel: catK, gaze: gaze, accessories: accessories)
        } else if Snapshots.active {
            GeometryReader { geo in
                Image(nsImage: IcosaNSView.still(mood: mood, size: geo.size))
            }
        } else {
            IcosaPetView(input: IcosaInput(mood: mood, progress: extras.progress, agents: extras.agents,
                                           scan: accessories.contains(.glasses), season: Self.season(accessories),
                                           motif: extras.motif),
                         entrance: extras.entrance, easterEgg: extras.easterEgg)
        }
    }

    /// Seasonal hats become seasonal particles.
    private static func season(_ a: Set<CatAccessory>) -> PetSeasonHat? {
        if a.contains(.witchHat) { return .witch }
        if a.contains(.santaHat) { return .santa }
        if a.contains(.beanie) { return .beanie }
        return nil
    }
}

enum PetStyle: String, CaseIterable, Identifiable {
    case icosa, cat
    var id: String { rawValue }
    var title: String { self == .icosa ? "Икосаэдр" : "Кот" }
}
