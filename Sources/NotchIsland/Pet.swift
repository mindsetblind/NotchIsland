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
}

/// The pet's face at a fixed size (agent rows, cards, peeks): the same neon cat as `PetView`,
/// fitted to `size` points of height. In snapshot mode (ImageRenderer can't draw NSViews) a still
/// image of the cat in that mood is shown instead.
struct PetFace: View {
    let mood: PetMood
    var size: CGFloat = 18
    var gaze: CGFloat? = nil

    var body: some View {
        CatView(mood: mood, pointsPerCSSPixel: size / 34, gaze: gaze)
            .frame(width: size * 1.6, height: size)
    }
}
