import Foundation
import SwiftUI

/// Geometry of the dock bar. Every value derives from the icon size so the dock stays
/// proportionally correct at any user-selected size (Appearance › Size).
public nonisolated struct DockMetrics: Sendable, Equatable {
    public var iconSize: Double
    public var spacing: Double
    public var horizontalPadding: Double
    public var verticalPadding: Double
    public var cornerRadius: Double
    public var bottomMargin: Double
    public var maxMagnification: Double
    public var magnificationRadiusInSlots: Double

    public var dividerWidth: Double { 1 }
    public var indicatorSize: Double { max(3, (iconSize * 0.075).rounded()) }
    public var labelHeight: Double { 24 }
    public var labelGap: Double { 10 }

    public init(
        iconSize: Double = 54,
        bottomMargin: Double = 6,
        maxMagnification: Double = 1.45,
        magnificationRadiusInSlots: Double = 2.7
    ) {
        let size = min(max(iconSize, 32), 96)
        self.iconSize = size
        self.spacing = min(max((size * 0.185).rounded(), 7), 14)
        self.horizontalPadding = min(max((size * 0.3).rounded(), 12), 22)
        self.verticalPadding = min(max((size * 0.185).rounded(), 7), 14)
        self.cornerRadius = min(max((size * 0.44).rounded(), 16), 32)
        self.bottomMargin = bottomMargin
        self.maxMagnification = min(max(maxMagnification, 1), 2.2)
        self.magnificationRadiusInSlots = magnificationRadiusInSlots
    }

    /// Height of the bar itself (icons plus vertical padding).
    public var barHeight: Double { iconSize + verticalPadding * 2 }
    /// Width of one icon slot in base coordinates.
    public var slotWidth: Double { iconSize + spacing }

    /// Space kept between the bar and the screen edges when the dock has to shrink to fit.
    public static let screenEdgeInset: Double = 24
    /// Icons never shrink below this size to fit; past it the bar may exceed the screen.
    public static let minimumFittedIconSize: Double = 24
    public var dividerSlotWidth: Double { spacing + dividerWidth }

    public var magnificationParameters: MagnificationParameters {
        MagnificationParameters(maxScale: maxMagnification, radius: slotWidth * magnificationRadiusInSlots)
    }

    /// Vertical room needed above the bar for magnified icons and the hover label.
    public var headroom: Double {
        iconSize * (maxMagnification - 1) + labelHeight + labelGap + 6
    }

    /// Room kept around the bar for the soft shadow.
    public var shadowInset: Double { 14 }
}

/// Geometry shared by popovers anchored to the dock (Agent Card, widget panels, Quick Peek).
public enum PanelMetrics {
    public static let cornerRadius: Double = 20
    public static let padding: Double = 14
    public static let rowSpacing: Double = 8
    public static let smallIcon: Double = 18
    public static let gapAboveDock: Double = 10
}

/// Typography tokens. The system font (San Francisco) is used throughout so Dynamic Type,
/// localisation and accessibility behave natively.
public enum PulseTypography {
    public static let dockLabel = Font.system(size: 12.5, weight: .medium)
    public static let island = Font.system(size: 12, weight: .medium)
    public static let islandSecondary = Font.system(size: 11.5, weight: .regular)
    public static let panelTitle = Font.system(size: 14, weight: .semibold)
    public static let panelHeadline = Font.system(size: 13, weight: .semibold)
    public static let panelBody = Font.system(size: 12.5, weight: .regular)
    public static let panelCaption = Font.system(size: 11, weight: .regular)
    public static let badge = Font.system(size: 10, weight: .bold, design: .rounded)
    public static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}
