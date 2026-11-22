import Foundation

/// Active writes execute in order. The latest unsent value for each property wins.
struct SelectionState {
  private var queue: [ControlChange] = []
  private var active: [ControlChange] = []
  private(set) var unconfirmed: [ControlChange] = []
  var hasQueued: Bool { !queue.isEmpty }
  var needsConfirmation: Bool { !unconfirmed.isEmpty }

  mutating func enqueue(_ batch: [ControlChange]) {
    for change in batch {
      queue.removeAll { $0.0 == change.0 && $0.1 == change.1 }
      queue.append(change)
    }
  }

  mutating func take() -> [ControlChange]? {
    guard !queue.isEmpty else { return nil }
    active = queue
    queue.removeAll()
    return active
  }

  func display(_ group: String, _ key: String) -> Any? {
    for changes in [queue, active, unconfirmed] {
      if let change = changes.last(where: { $0.0 == group && $0.1 == key }) {
        return change.2
      }
    }
    return nil
  }

  mutating func finishBatch() { active.removeAll() }
  mutating func clearUnconfirmed() { unconfirmed.removeAll() }

  mutating func recordSent(_ change: ControlChange) {
    unconfirmed.removeAll { $0.0 == change.0 && $0.1 == change.1 }
    unconfirmed.append(change)
  }

  func hasUnconfirmed(_ group: String, _ key: String) -> Bool {
    unconfirmed.contains { $0.0 == group && $0.1 == key }
  }

  mutating func confirm(_ matches: [ControlChange]) {
    for change in matches {
      unconfirmed.removeAll { $0.0 == change.0 && $0.1 == change.1 && equal($0.2, change.2) }
    }
  }
}

struct AutoRetry {
  private(set) var failures = 0
  var stopped: Bool { failures >= 5 }
  var delay: TimeInterval { failures == 0 ? 0 : pow(2, Double(failures)) }
  mutating func fail() { failures = min(5, failures + 1) }
}
