import AgentCore
import Foundation

/// Plays `DemoScenario` in real time, looping. Demo events are fixtures: always labelled,
/// never persisted.
final class DemoPlayer {
    private let deliver: ([AgentEvent]) -> Void
    private var task: Task<Void, Never>?
    private let loopLength: TimeInterval = 75

    init(deliver: @escaping ([AgentEvent]) -> Void) {
        self.deliver = deliver
    }

    func start() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let start = Date()
                var elapsed: TimeInterval = 0
                // An empty batch marks a new loop: previous demo sessions are cleared.
                self.deliver([])
                for step in DemoScenario.standard(start: start) {
                    let wait = step.offset - elapsed
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    guard !Task.isCancelled else { return }
                    elapsed = step.offset
                    var event = step.event
                    // Unique ids per loop so the engine does not treat repeats as duplicates.
                    event.id += "-\(Int(start.timeIntervalSince1970))"
                    self.deliver([event])
                }
                try? await Task.sleep(for: .seconds(max(1, self.loopLength - elapsed)))
            }
        }
    }

    func restart() {
        start()
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
