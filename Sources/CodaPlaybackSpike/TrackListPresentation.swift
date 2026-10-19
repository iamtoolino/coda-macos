import Foundation

struct QueueDiscSection {
  let range: Range<Int>
  let number: Int
  let subtitle: String?
  let durationSeconds: Int
  let entryIDs: [UUID]
}

struct QueueGroup: Identifiable {
  let id: UUID
  let startIndex: Int
  let entries: [QueueEntry]
  let entryIDs: [UUID]
  let showsDiscHeadings: Bool
  let discSections: [QueueDiscSection]
  private let discSectionIndices: [Int]
  let detail: String

  init(id: UUID, startIndex: Int, entries: [QueueEntry]) {
    self.id = id
    self.startIndex = startIndex
    self.entries = entries
    entryIDs = entries.map(\.id)
    detail = albumGroupDetail(year: entries.first?.year,
                             durationSeconds: entries.reduce(0) { $0 + $1.durationSeconds })
    var sections: [QueueDiscSection] = []
    var indices: [Int] = []
    var start = 0
    while start < entries.count {
      let number = max(1, entries[start].discNumber ?? 1)
      var end = start + 1
      while end < entries.count, max(1, entries[end].discNumber ?? 1) == number { end += 1 }
      let slice = entries[start..<end]
      indices.append(contentsOf: repeatElement(sections.count, count: end - start))
      sections.append(QueueDiscSection(
        range: start..<end, number: number,
        subtitle: slice.first { $0.discSubtitle?.nonEmpty != nil }?.discSubtitle,
        durationSeconds: slice.reduce(0) { $0 + $1.durationSeconds },
        entryIDs: slice.map(\.id)
      ))
      start = end
    }
    discSections = sections
    discSectionIndices = indices
    showsDiscHeadings = Set(sections.map(\.number)).count > 1
      || sections.contains { $0.subtitle != nil }
  }

  var isStandalone: Bool { entries.count == 1 }
  var albumID: String? { AlbumSequenceResolver.normalizedAlbumID(entries.first?.albumID) }
  var albumTitle: String { entries.first?.album.nonEmpty ?? "Unknown Album" }
  var artist: String { entries.first?.albumArtistName.nonEmpty ?? "Unknown Artist" }

  func discSectionIndex(at offset: Int) -> Int? {
    guard discSectionIndices.indices.contains(offset) else { return nil }
    return discSectionIndices[offset]
  }

  func beginsDiscSection(at offset: Int) -> Bool {
    guard showsDiscHeadings, let section = discSection(at: offset) else { return false }
    return section.range.lowerBound == offset
  }

  func discNumber(at offset: Int) -> Int { discSection(at: offset)?.number ?? 1 }
  func discSubtitle(at offset: Int) -> String? { discSection(at: offset)?.subtitle }
  func discDuration(at offset: Int) -> Int { discSection(at: offset)?.durationSeconds ?? 0 }
  func discEntryIDs(at offset: Int) -> [UUID] { discSection(at: offset)?.entryIDs ?? [] }

  private func discSection(at offset: Int) -> QueueDiscSection? {
    guard let index = discSectionIndex(at: offset) else { return nil }
    return discSections[index]
  }
}

struct IndexedSong: Identifiable {
  let index: Int
  let song: RemoteSong
  var id: String { "\(index):\(song.id)" }
}

struct PlaylistGroup: Identifiable {
  let id: Int
  let songs: [IndexedSong]
  var isStandalone: Bool { songs.count == 1 }
  var albumID: String? { AlbumSequenceResolver.normalizedAlbumID(songs.first?.song.albumId) }

  var albumTitle: String { songs.first?.song.albumName.nonEmpty ?? "Unknown Album" }
  var artist: String { songs.first?.song.albumArtistName.nonEmpty ?? "Unknown Artist" }
  var detail: String {
    albumGroupDetail(year: songs.first?.song.year,
                     durationSeconds: songs.compactMap { $0.song.duration }.reduce(0, +))
  }
}

func queueGroups(_ entries: [QueueEntry]) -> [QueueGroup] {
  AlbumSequenceResolver.groups(albumIDs: entries.map(\.albumID)).map { group in
    QueueGroup(id: entries[group.range.lowerBound].id, startIndex: group.range.lowerBound,
               entries: Array(entries[group.range]))
  }
}

func playlistGroups(_ songs: [RemoteSong]) -> [PlaylistGroup] {
  AlbumSequenceResolver.groups(albumIDs: songs.map(\.albumId)).map { group in
    PlaylistGroup(id: group.range.lowerBound,
                  songs: group.range.map { IndexedSong(index: $0, song: songs[$0]) })
  }
}

private func albumGroupDetail(year: Int?, durationSeconds: Int) -> String {
  [year.map(String.init), formatCollectionDuration(durationSeconds).nonEmpty]
    .compactMap { $0 }.joined(separator: " · ")
}
