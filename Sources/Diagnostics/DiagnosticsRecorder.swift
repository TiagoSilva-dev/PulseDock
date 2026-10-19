import Foundation
import os
import Synchronization

/// A bounded, in-memory record of notable events used by the Diagnostics pane and by
/// "Export sanitized logs". Entries are sanitized by construction: only short,
/// developer-authored messages and identifiers are stored.
public final class DiagnosticsRecorder: Sendable {
    public struct Entry: Sendable, Codable, Identifiable, Hashable {
        public enum Level: String, Sendable, Codable { case info, notice, warning, error }
        public let id: UUID
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String

        public init(id: UUID = UUID(), date: Date = Date(), level: Level, category: String, message: String) {
            self.id = id
            self.date = date
            self.level = level
            self.category = category
            self.message = message
        }
    }

    public static let shared = DiagnosticsRecorder(capacity: 500)

    private let capacity: Int
    private let storage: Mutex<[Entry]>
    private let counters: Mutex<[String: Int]>

    public init(capacity: Int) {
        self.capacity = max(10, capacity)
        self.storage = Mutex([])
        self.counters = Mutex([:])
    }

    public func record(_ level: Entry.Level, _ category: String, _ message: String) {
        let entry = Entry(level: level, category: category, message: String(message.prefix(400)))
        // Mirrored to the unified log (`log show --predicate 'subsystem == "…"'`). Callers only
        // record infrastructure facts (states, counts, errors), never prompts or command text.
        let logger = Logger(subsystem: PulseLog.subsystem, category: category)
        switch level {
        case .error: logger.error("\(entry.message, privacy: .public)")
        case .warning: logger.warning("\(entry.message, privacy: .public)")
        default: logger.info("\(entry.message, privacy: .public)")
        }
        storage.withLock { entries in
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    /// Increments a named counter (e.g. "bridge.messages.accepted").
    public func increment(_ counter: String, by value: Int = 1) {
        counters.withLock { $0[counter, default: 0] += value }
    }

    public func counterValue(_ counter: String) -> Int {
        counters.withLock { $0[counter] ?? 0 }
    }

    public var allCounters: [String: Int] {
        counters.withLock { $0 }
    }

    public var entries: [Entry] {
        storage.withLock { $0 }
    }

    public func clear() {
        storage.withLock { $0.removeAll() }
        counters.withLock { $0.removeAll() }
    }
}
