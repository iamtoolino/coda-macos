import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Album sequences")
struct AlbumSequenceResolverTests {
  @Test("Mixed queues preserve both ends of every album run")
  func mixedQueue() {
    let queue = ["A", "A", "B", "C", "C", "D"].map { entry($0) }
    #expect(queue.indices.map {
      AlbumSequenceResolver.context(in: queue, at: $0)!.isAlbumSequence
    } == [true, true, false, true, true, false])
    #expect(AlbumSequenceResolver.context(in: queue, at: 0)?.continuesPrevious == false)
    #expect(AlbumSequenceResolver.context(in: queue, at: 1)?.continuesNext == false)
  }

  @Test("Membership uses album identity, not metadata or disc boundaries")
  func identity() {
    let queue = [
      entry("A", disc: 1), entry("A", disc: 2), entry("B"),
      entry(nil), entry(""), entry(" "),
    ]
    #expect(queue.indices.map {
      AlbumSequenceResolver.context(in: queue, at: $0)!.isAlbumSequence
    } == [true, true, false, false, false, false])
  }

  @Test("Queue ends, singletons, and invalid indices do not create sequences")
  func boundaries() {
    let queue = ["A", "B", "A"].map { entry($0) }
    #expect(queue.indices.allSatisfy {
      AlbumSequenceResolver.context(in: queue, at: $0)?.isAlbumSequence == false
    })
    #expect(AlbumSequenceResolver.context(in: [entry("A")], at: 0)?.isAlbumSequence == false)
    #expect(AlbumSequenceResolver.context(in: [], at: 0) == nil)
    #expect(AlbumSequenceResolver.context(in: queue, at: -1) == nil)
    #expect(AlbumSequenceResolver.context(in: queue, at: 3) == nil)
  }

  private func entry(_ albumID: String?, disc: Int = 1) -> QueueEntry {
    QueueEntry(
      sourceID: UUID().uuidString, url: URL(string: "https://example.test/audio")!,
      title: "Song", artist: "Artist", album: "Same title",
      albumID: albumID, discNumber: disc
    )
  }
}
