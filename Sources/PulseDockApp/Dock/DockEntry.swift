import AppKit
import DockCore
import DockRendering
import Foundation

/// One element shown in the dock bar.
struct DockEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        /// An application: pinned (`pinned != nil`), running (`running != nil`) or both.
        case application(pinned: PinnedItem?, running: RunningApp?)
        case folder(PinnedItem)
        case trash
        case widget(WidgetPlacement)
        case agentPulse
        case divider
        /// Empty slot shown while something is dragged over the dock.
        case placeholder
    }

    let id: String
    var kind: Kind
    var title: String
    var url: URL?
    var isMissing = false

    var slotKind: DockSlotSpec.Kind {
        switch kind {
        case .application, .folder, .trash, .placeholder: .icon
        case .widget, .agentPulse: .fixed
        case .divider: .divider
        }
    }

    var running: RunningApp? {
        if case let .application(_, running) = kind { return running }
        return nil
    }

    var pinned: PinnedItem? {
        switch kind {
        case let .application(pinned, _): pinned
        case let .folder(pinned): pinned
        default: nil
        }
    }

    var isApplication: Bool {
        if case .application = kind { return true }
        return false
    }

    /// Entries that can be reordered by dragging (and removed by dragging out).
    var isReorderable: Bool {
        switch kind {
        case .application, .folder: true
        default: false
        }
    }

    var iconPath: String? {
        switch kind {
        case .application, .folder: url?.path ?? pinned?.path
        default: nil
        }
    }
}

/// What the pointer or a drag is currently doing, used to render feedback.
struct DockDragState: Equatable {
    enum Source: Equatable {
        /// Reordering an existing entry.
        case internalEntry(String)
        /// Files or apps dragged from another app (Finder).
        case external(acceptsPinning: Bool)
    }

    var source: Source
    var location: CGPoint
    /// Index (in the reorderable section) where the dragged item would land.
    var insertionIndex: Int?
    /// Entry the drop would act on (open files with an app, move to Trash).
    var targetEntryID: String?
    /// Internal drag moved far enough above the dock to remove the item.
    var removeIntent = false
}
