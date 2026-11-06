import CoreGraphics
import Testing
@testable import OrcaBrowser

struct StackMetricsTests {
    let metrics = StackMetrics(screen: CGSize(width: 402, height: 874), topInset: 62)

    @Test func cardsHaveTheScreensProportions() {
        let card = metrics.cardSize
        #expect(abs(card.width / card.height - 402 / 874) < 0.0001)
    }

    @Test func restingPreviewsFillCardsWithoutChromeInsets() {
        let layout = previewLayout(expansion: 0)
        #expect(layout.topInset == 0)
        #expect(layout.height == metrics.cardHeight)
        #expect(layout.pageSize.width * layout.scale >= metrics.cardWidth)
        #expect(layout.pageSize.height * layout.scale >= metrics.cardHeight)
    }

    @Test func expandedPreviewsMatchTheBrowserViewport() {
        let layout = previewLayout(expansion: 1)
        let fullScreenScale = metrics.screen.width / metrics.cardWidth
        #expect(abs(layout.topInset * fullScreenScale - metrics.topInset) < 0.001)
        #expect(abs(layout.scale * fullScreenScale - 1) < 0.001)
        #expect(abs(layout.height * fullScreenScale - layout.pageSize.height) < 0.001)
    }

    @Test func previewFramingInterpolatesDuringExpansion() {
        let resting = previewLayout(expansion: 0)
        let expanded = previewLayout(expansion: 1)
        let halfway = previewLayout(expansion: 0.5)
        #expect(abs(halfway.scale - (resting.scale + expanded.scale) / 2) < 0.001)
        #expect(abs(halfway.height - (resting.height + expanded.height) / 2) < 0.001)
        #expect(abs(halfway.topInset - expanded.topInset / 2) < 0.001)
    }

    private func previewLayout(expansion: CGFloat) -> CardPreviewLayout {
        CardPreviewLayout(
            cardSize: metrics.cardSize,
            pageSize: CGSize(width: metrics.screen.width, height: metrics.screen.height - metrics.topInset - 34 - 70),
            contentTop: metrics.contentTop,
            expansion: expansion
        )
    }

    @Test func aFullyExpandedCardFillsTheScreen() {
        let pose = metrics.pose(relative: 3, entrance: 1, expand: 1, startTilt: 8)
        #expect(abs(pose.center.x - 201) < 0.001)
        #expect(abs(pose.center.y - 437) < 0.001)
        #expect(abs(pose.scale * metrics.cardWidth - 402) < 0.001)
        #expect(pose.rotation == 0)
        #expect(pose.cornerRadius == 0)
    }

    @Test func theFocusedCardIsDrawnUndimmed() {
        let pose = metrics.pose(relative: 0, entrance: 1, expand: 0, startTilt: 8)
        #expect(pose.opacity == 1)
        #expect(pose.dim == 0)
        #expect(pose.scale == 1)
    }

    @Test func olderCardsShrinkAndDarkenWithinLimits() {
        for d in stride(from: -1.0, through: -20, by: -1) {
            #expect(metrics.scale(forRelative: d) >= 0.88)
            #expect(metrics.dim(forRelative: d) <= 0.3)
        }
    }

    @Test func restingCardsFarOffScreenAreNotDrawn() {
        #expect(metrics.pose(relative: -30, entrance: 1, expand: 0, startTilt: 8).opacity == 0)
        #expect(metrics.pose(relative: 6, entrance: 1, expand: 0, startTilt: 8).opacity == 0)
        // ...but neighbors just out of view are, so paging to them is smooth.
        #expect(metrics.pose(relative: -1, entrance: 1, expand: 0, startTilt: 8).opacity == 1)
        #expect(metrics.pose(relative: 1, entrance: 1, expand: 0, startTilt: 8).opacity == 1)
    }

    @Test func cardsInMotionAreAlwaysDrawn() {
        // Mid-entrance and mid-expansion, even from far away.
        #expect(metrics.pose(relative: -30, entrance: 0.5, expand: 0, startTilt: 8).opacity > 0)
        #expect(metrics.pose(relative: -30, entrance: 1, expand: 0.5, startTilt: 8).opacity > 0)
    }
}
