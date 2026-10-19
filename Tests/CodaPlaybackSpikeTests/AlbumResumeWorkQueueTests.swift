import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Album resume operation ordering")
@MainActor
struct AlbumResumeWorkQueueTests {
  @Test("Retention completes before a later completion can advance the same anchor")
  func retentionBeforeCompletion() async {
    let queue = AlbumResumeWorkQueue()
    let gate = Gate()
    var events: [String] = []
    var marker: String? = "old"
    let refresh = queue.enqueue {
      events.append("fetch")
      await gate.wait()
      marker = nil
      events.append("delete")
    }
    await gate.waitUntilBlocked()
    let completion = queue.enqueue {
      marker = "advanced"
      events.append("upsert")
    }
    await Task.yield()
    #expect(events == ["fetch"])
    gate.release()
    await refresh.value
    await completion.value
    #expect(events == ["fetch", "delete", "upsert"])
    #expect(marker == "advanced")
  }

  @Test("Refresh fetches after a preceding completion rather than queuing stale candidates")
  func completionBeforeRefresh() async {
    let queue = AlbumResumeWorkQueue()
    let gate = Gate()
    var marker = "old"
    var fetched: String?
    queue.enqueue {
      await gate.wait()
      marker = "advanced"
    }
    await gate.waitUntilBlocked()
    let refresh = queue.enqueue { fetched = marker }
    await Task.yield()
    #expect(fetched == nil)
    gate.release()
    await refresh.value
    #expect(fetched == "advanced")
  }

  @Test("Session invalidation discards all queued old work and permits a new session")
  func invalidation() async {
    let queue = AlbumResumeWorkQueue()
    let gate = Gate()
    queue.enqueue { await gate.wait() }
    await gate.waitUntilBlocked()
    var staleWrites = 0
    let first = queue.enqueue { staleWrites += 1 }
    let second = queue.enqueue { staleWrites += 1 }
    queue.cancel()
    var refreshed = false
    await queue.enqueue { refreshed = true }.value
    gate.release()
    await first.value
    await second.value
    #expect(refreshed)
    #expect(staleWrites == 0)
  }
}

@MainActor
private final class Gate {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilBlocked() async {
    while continuation == nil { await Task.yield() }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
