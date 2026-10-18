import Foundation

/// Ordered-track context, independent of rendering, normalization, and progress tracking.
struct AlbumSequenceContext: Equatable, Sendable {
  let albumID: String?
  let continuesPrevious: Bool
  let continuesNext: Bool
  var isExplicitContinuation: Bool = false

  var isAlbumSequence: Bool { continuesPrevious || continuesNext }
}

struct AlbumSequenceGroup: Equatable, Sendable {
  let range: Range<Int>
  let albumID: String?

  var isAlbumSequence: Bool { albumID != nil && range.count > 1 }
}

enum AlbumSequenceResolver {
  /// A queue belongs to one server session. Never join its ends for repeat playback.
  static func context(in queue: [QueueEntry], at index: Int) -> AlbumSequenceContext? {
    guard queue.indices.contains(index) else { return nil }
    return context(
      albumID: queue[index].albumID,
      previousAlbumID: index > 0 ? queue[index - 1].albumID : nil,
      nextAlbumID: index + 1 < queue.count ? queue[index + 1].albumID : nil,
      continuationAlbumID: queue[index].albumContinuationID
    )
  }

  /// Metadata-only entry point for lists that do not contain playback queue entries.
  static func context(
    albumID: String?, previousAlbumID: String?, nextAlbumID: String?,
    continuationAlbumID: String? = nil
  ) -> AlbumSequenceContext {
    let albumID = normalizedAlbumID(albumID)
    return AlbumSequenceContext(
      albumID: albumID,
      continuesPrevious: albumID != nil && albumID == normalizedAlbumID(previousAlbumID),
      continuesNext: albumID != nil && albumID == normalizedAlbumID(nextAlbumID),
      isExplicitContinuation: albumID != nil
        && albumID == normalizedAlbumID(continuationAlbumID)
    )
  }

  /// Contiguous runs only: never reorder items, join queue ends, or infer missing identities.
  static func groups(albumIDs: [String?]) -> [AlbumSequenceGroup] {
    guard !albumIDs.isEmpty else { return [] }
    let identities = albumIDs.map(normalizedAlbumID)
    var groups: [AlbumSequenceGroup] = []
    var start = 0
    for index in 1..<identities.count {
      if context(albumID: identities[index], previousAlbumID: identities[index - 1],
                 nextAlbumID: nil).continuesPrevious {
        continue
      }
      groups.append(AlbumSequenceGroup(range: start..<index, albumID: identities[start]))
      start = index
    }
    groups.append(AlbumSequenceGroup(range: start..<identities.count, albumID: identities[start]))
    return groups
  }

  static func normalizedAlbumID(_ id: String?) -> String? {
    let value = id?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}
