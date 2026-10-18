import Foundation

/// Queue context, independent of rendering, normalization, and progress tracking.
struct AlbumSequenceContext: Equatable, Sendable {
  let albumID: String?
  let continuesPrevious: Bool
  let continuesNext: Bool
  var isExplicitContinuation: Bool = false

  var isAlbumSequence: Bool { continuesPrevious || continuesNext }
}

enum AlbumSequenceResolver {
  /// A queue belongs to one server session. Never join its ends for repeat playback.
  static func context(in queue: [QueueEntry], at index: Int) -> AlbumSequenceContext? {
    guard queue.indices.contains(index) else { return nil }
    let albumID = identity(queue[index])
    func matches(_ neighbour: Int) -> Bool {
      guard let albumID, queue.indices.contains(neighbour) else { return false }
      return identity(queue[neighbour]) == albumID
    }
    return AlbumSequenceContext(
      albumID: albumID,
      continuesPrevious: matches(index - 1),
      continuesNext: matches(index + 1),
      isExplicitContinuation: albumID != nil
        && queue[index].albumContinuationID?.trimmingCharacters(in: .whitespacesAndNewlines) == albumID
    )
  }

  private static func identity(_ entry: QueueEntry) -> String? {
    guard let id = entry.albumID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !id.isEmpty
    else { return nil }
    return id
  }
}
