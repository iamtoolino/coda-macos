import Foundation

struct QueueGroup: Identifiable {
  let id: UUID
  let startIndex: Int
  let entries: [QueueEntry]

  var isStandalone: Bool { entries.count == 1 }
  var entryIDs: [UUID] { entries.map(\.id) }
  var albumID: String? { AlbumSequenceResolver.normalizedAlbumID(entries.first?.albumID) }

  var albumTitle: String { entries.first?.album.nonEmptyGroupValue ?? "Unknown Album" }
  var artist: String { entries.first?.albumArtistName.nonEmptyGroupValue ?? "Unknown Artist" }

  var showsDiscHeadings: Bool {
    Set(entries.map(normalizedDiscNumber)).count > 1
      || entries.contains { $0.discSubtitle?.nonEmptyGroupValue != nil }
  }

  var detail: String {
    albumGroupDetail(year: entries.first?.year,
                     durationSeconds: entries.reduce(0) { $0 + $1.durationSeconds })
  }

  func beginsDiscSection(at offset: Int) -> Bool {
    guard showsDiscHeadings, entries.indices.contains(offset) else { return false }
    guard offset > 0 else { return true }
    return normalizedDiscNumber(entries[offset - 1]) != normalizedDiscNumber(entries[offset])
  }

  func discNumber(at offset: Int) -> Int {
    guard entries.indices.contains(offset) else { return 1 }
    return normalizedDiscNumber(entries[offset])
  }

  func discSubtitle(at offset: Int) -> String? {
    discSection(at: offset).first {
      $0.discSubtitle?.nonEmptyGroupValue != nil
    }?.discSubtitle
  }

  func discDuration(at offset: Int) -> Int {
    discSection(at: offset).reduce(0) { $0 + $1.durationSeconds }
  }

  func discEntryIDs(at offset: Int) -> [UUID] {
    discSection(at: offset).map(\.id)
  }

  private func discSection(at offset: Int) -> ArraySlice<QueueEntry> {
    guard entries.indices.contains(offset) else { return entries[0..<0] }
    let number = discNumber(at: offset)
    var start = offset
    var end = offset + 1
    while start > 0, normalizedDiscNumber(entries[start - 1]) == number { start -= 1 }
    while end < entries.count, normalizedDiscNumber(entries[end]) == number { end += 1 }
    return entries[start..<end]
  }

  private func normalizedDiscNumber(_ entry: QueueEntry) -> Int {
    max(1, entry.discNumber ?? 1)
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

  var albumTitle: String { songs.first?.song.albumName.nonEmptyGroupValue ?? "Unknown Album" }
  var artist: String { songs.first?.song.albumArtistName.nonEmptyGroupValue ?? "Unknown Artist" }
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
  [year.map(String.init), formatCollectionDuration(durationSeconds).nonEmptyGroupValue]
    .compactMap { $0 }.joined(separator: " · ")
}

private extension String {
  var nonEmptyGroupValue: String? { isEmpty ? nil : self }
}
