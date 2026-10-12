import CoreGraphics
import Testing
@testable import NotchIslandCore

struct ScreenPlacementTests {
    // MacBook Pro 14" (default scaling): 1512×982, 32pt notch, ~185pt wide.
    let builtIn = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                             visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                             safeTop: 32, auxLeftWidth: 663.5, auxRightWidth: 663.5)
    let external = ScreenInfo(id: 2, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                              visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))

    @Test func prefersTheNotchedDisplayWhereverItIsInTheList() {
        #expect(ScreenPlacement.pick([external, builtIn])?.id == 1)
        #expect(ScreenPlacement.pick([builtIn, external])?.id == 1)
    }

    @Test func fallsBackToThePrimaryDisplayWithTheLidClosed() {
        let other = ScreenInfo(id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        #expect(ScreenPlacement.pick([external, other])?.id == 2)
    }

    @Test func noDisplaysMeansNoPlacement() {
        #expect(ScreenPlacement.pick([]) == nil)
    }

    @Test func notchSizeComesFromTheMenuBarAreas() {
        let size = ScreenPlacement.notchSize(of: builtIn)
        #expect(size == CGSize(width: 185, height: 32))
    }

    @Test func displaysWithoutNotchGetAMenuBarHighPill() {
        #expect(ScreenPlacement.notchSize(of: external) == CGSize(width: 190, height: 25))
        // Auto-hidden menu bar: visible frame reaches the top.
        let hidden = ScreenInfo(id: 4, frame: external.frame, visibleFrame: external.frame)
        #expect(ScreenPlacement.notchSize(of: hidden).height == 24)
    }

    @Test func safeAreaWithoutAuxiliaryAreasIsNotANotch() {
        let odd = ScreenInfo(id: 5, frame: external.frame, visibleFrame: external.visibleFrame, safeTop: 20)
        #expect(!odd.hasNotch)
    }

    @Test func panelIsCenteredAtTheTopOfItsDisplay() {
        let f = ScreenPlacement.panelFrame(canvas: CGSize(width: 760, height: 640), on: external)
        #expect(f.midX == external.frame.midX)
        #expect(f.maxY == external.frame.maxY)
    }

    @Test func hitAreaHugsTheIslandOnTheChosenDisplay() {
        let r = ScreenPlacement.islandRect(size: CGSize(width: 265, height: 32), padding: 8, on: builtIn)
        #expect(r.contains(CGPoint(x: 756, y: 975)))
        #expect(!r.contains(CGPoint(x: 756, y: 900)))     // below: never covers content under the menu bar
        #expect(!r.contains(CGPoint(x: 2000, y: 975)))    // other display
    }
}
