import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let codaQueueDropItem = UTType(
    exportedAs: "io.github.iamtoolino.coda.macos.queue-drop-item",
    conformingTo: .data
  )
}

struct LibraryQueueDragItem: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable {
    case album
    case albumDisc
    case artist
    case playlist
    case song
    case songs
  }

  let kind: Kind
  let id: String
  var discNumber: Int? = nil
  var songIDs: [String]? = nil
  var canonicalAlbumArtworkID: String? = nil

  static func album(_ id: String) -> Self { Self(kind: .album, id: id) }
  static func albumDisc(_ id: String, discNumber: Int) -> Self {
    Self(
      kind: .albumDisc,
      id: id,
      discNumber: max(1, discNumber)
    )
  }
  static func artist(_ id: String) -> Self { Self(kind: .artist, id: id) }
  static func playlist(_ id: String) -> Self { Self(kind: .playlist, id: id) }
  static func song(_ id: String, canonicalAlbumArtworkID: String? = nil) -> Self {
    Self(kind: .song, id: id, canonicalAlbumArtworkID: canonicalAlbumArtworkID)
  }
  static func songs(_ ids: [String], canonicalAlbumArtworkID: String? = nil) -> Self {
    Self(
      kind: .songs,
      id: ids.first ?? "",
      songIDs: ids,
      canonicalAlbumArtworkID: canonicalAlbumArtworkID
    )
  }
}

struct QueueReorderDragItem: Codable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable {
    case albumBlock
    case track
  }

  let kind: Kind
  let entryIDs: [UUID]

  static func albumBlock(_ entryIDs: [UUID]) -> Self {
    Self(kind: .albumBlock, entryIDs: entryIDs)
  }

  static func track(_ entryID: UUID) -> Self {
    Self(kind: .track, entryIDs: [entryID])
  }

  static func tracks(_ entryIDs: [UUID]) -> Self {
    Self(kind: .track, entryIDs: entryIDs)
  }
}

enum QueueDropItem: Codable, Hashable, Sendable, Transferable {
  case library(LibraryQueueDragItem)
  case reorder(QueueReorderDragItem)

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .codaQueueDropItem)
  }
}

extension DragConfiguration {
  static func codaInternal(allowMove: Bool = false) -> Self {
    Self(
      operationsWithinApp: .init(allowCopy: true, allowMove: allowMove),
      operationsOutsideApp: .init(allowCopy: false)
    )
  }
}

func reorderedQueueIDs(
  _ currentIDs: [UUID],
  moving movingIDs: [UUID],
  before targetID: UUID?
) -> [UUID]? {
  let movingSet = Set(movingIDs)
  guard !movingSet.isEmpty,
    movingSet.count == movingIDs.count,
    movingSet.isSubset(of: Set(currentIDs)),
    targetID.map({ !movingSet.contains($0) }) ?? true
  else { return nil }

  let orderedMovingIDs = currentIDs.filter { movingSet.contains($0) }
  var reordered = currentIDs.filter { !movingSet.contains($0) }
  let insertionIndex: Int
  if let targetID {
    guard let targetIndex = reordered.firstIndex(of: targetID) else { return nil }
    insertionIndex = targetIndex
  } else {
    insertionIndex = reordered.endIndex
  }
  reordered.insert(contentsOf: orderedMovingIDs, at: insertionIndex)
  return reordered == currentIDs ? nil : reordered
}

struct ServerDetails: Equatable, Sendable {
  let software: String?
  let version: String?
  let apiVersion: String?
  let supportsOpenSubsonic: Bool?
}

struct QueueEntry: Identifiable, Hashable, Sendable {
  let id: UUID
  let sourceID: String
  let url: URL
  let artworkURL: URL?
  let nowPlayingArtworkURL: URL?
  let title: String
  let artist: String
  let album: String
  let albumID: String?
  let queueGroupID: UUID?
  let year: Int?
  let trackNumber: Int?
  let discNumber: Int?
  let discSubtitle: String?
  let durationSeconds: Int
  let formatDescription: String

  init(
    id: UUID = UUID(),
    sourceID: String,
    url: URL,
    artworkURL: URL? = nil,
    nowPlayingArtworkURL: URL? = nil,
    title: String,
    artist: String = "",
    album: String = "",
    albumID: String? = nil,
    queueGroupID: UUID? = nil,
    year: Int? = nil,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    discSubtitle: String? = nil,
    durationSeconds: Int = 0,
    formatDescription: String = ""
  ) {
    self.id = id
    self.sourceID = sourceID
    self.url = url
    self.artworkURL = artworkURL
    self.nowPlayingArtworkURL = nowPlayingArtworkURL
    self.title = title
    self.artist = artist
    self.album = album
    self.albumID = albumID
    self.queueGroupID = queueGroupID
    self.year = year
    self.trackNumber = trackNumber
    self.discNumber = discNumber
    self.discSubtitle = discSubtitle
    self.durationSeconds = durationSeconds
    self.formatDescription = formatDescription
  }
}

func albumGroupingIdentity(albumID: String?, artist: String, album: String) -> String {
  if let albumID = albumID?.trimmingCharacters(in: .whitespacesAndNewlines), !albumID.isEmpty {
    return "album:\(albumID)"
  }
  let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  let normalizedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return "metadata:\(normalizedArtist)|\(normalizedAlbum)"
}

struct RemoteSong: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  var album: String? = nil
  var artist: String? = nil
  var displayAlbumArtist: String? = nil
  var albumId: String? = nil
  var artistId: String? = nil
  var coverArt: String? = nil
  var track: Int? = nil
  var discNumber: Int? = nil
  var discSubtitle: String? = nil
  var duration: Int? = nil
  var year: Int? = nil
  var suffix: String? = nil
  var contentType: String? = nil
  var bitRate: Int? = nil
  var bitDepth: Int? = nil
  var samplingRate: Int? = nil

  var albumName: String { album ?? "" }
  var artistName: String { displayAlbumArtist?.nonEmptyValue ?? artist ?? "" }
  var albumArtworkID: String? {
    if let albumId, !albumId.isEmpty { return albumId }
    return coverArt
  }

  var technicalSummary: String {
    var parts: [String] = []
    if let suffix, !suffix.isEmpty {
      parts.append(suffix.uppercased())
    }
    if let bitDepth {
      parts.append("\(bitDepth)-bit")
    }
    if let samplingRate {
      let kilohertz = Double(samplingRate) / 1_000
      parts.append(kilohertz.formatted(.number.precision(.fractionLength(0...1))) + " kHz")
    }
    if let bitRate {
      parts.append("\(bitRate) kbps")
    }
    return parts.joined(separator: " · ")
  }
}

struct RemoteAlbum: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  var artist: String? = nil
  var artistId: String? = nil
  var coverArt: String? = nil
  var songCount: Int? = nil
  var duration: Int? = nil
  var created: String? = nil
  var year: Int? = nil
  var originalReleaseDate: ItemDate? = nil
  var releaseDate: ItemDate? = nil
  var playCount: Int? = nil
  var userRating: Int? = nil
  var discTitles: [RemoteDiscTitle]? = nil

  var artistName: String { artist ?? "" }
  var artworkID: String { coverArt ?? id }

  var releaseYear: Int? {
    originalReleaseDate?.year ?? releaseDate?.year ?? year
  }

  var chronologicalReleaseKey: (Int, Int, Int) {
    (
      originalReleaseDate?.year ?? releaseDate?.year ?? year ?? Int.max,
      originalReleaseDate?.month ?? releaseDate?.month ?? 13,
      originalReleaseDate?.day ?? releaseDate?.day ?? 32
    )
  }
}

struct RemoteDiscTitle: Decodable, Hashable, Sendable {
  let disc: Int
  let title: String
  var coverArt: String? = nil
}

struct RemoteArtist: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  var albumCount: Int? = nil
  var coverArt: String? = nil
  var artistImageUrl: String? = nil
  var genre: String? = nil

  var isAlbumArtistSearchResult: Bool {
    guard let albumCount else {
      // Some Subsonic-compatible servers omit this optional field. Preserve
      // those results instead of assuming they are participation-only artists.
      return true
    }
    return albumCount > 0
  }
}

struct RemotePlaylist: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  var songCount: Int? = nil
  var duration: Int? = nil
  var changed: String? = nil
  var coverArt: String? = nil
  var owner: String? = nil
  var entry: [RemoteSong]? = nil

  var songs: [RemoteSong] { entry ?? [] }
}

struct RemotePlayQueue: Decodable, Hashable, Sendable {
  var current: String? = nil
  var position: Int? = nil
  var changed: String? = nil
  var changedBy: String? = nil
  var currentIndex: Int? = nil
  var entry: [RemoteSong]? = nil

  var songs: [RemoteSong] { entry ?? [] }

  var resolvedCurrentIndex: Int {
    if let currentIndex, songs.indices.contains(currentIndex) {
      return currentIndex
    }
    if let current, let index = songs.firstIndex(where: { $0.id == current }) {
      return index
    }
    return 0
  }

  var wasWrittenByThisCoda: Bool {
    changedBy?.caseInsensitiveCompare(NavidromeConfiguration.clientName) == .orderedSame
  }

  var handoffIdentity: String {
    ([changed ?? "", changedBy ?? "", current ?? "", String(position ?? 0)] + songs.map(\.id))
      .joined(separator: "|")
  }
}

struct ItemDate: Decodable, Hashable, Sendable {
  var year: Int? = nil
  var month: Int? = nil
  var day: Int? = nil
}

struct AlbumPage: Hashable, Sendable {
  let album: RemoteAlbum
  let songs: [RemoteSong]

  var discSections: [AlbumDiscSection] {
    let subtitles = Dictionary(
      (album.discTitles ?? []).map {
        (max(1, $0.disc), $0.title.trimmingCharacters(in: .whitespacesAndNewlines))
      },
      uniquingKeysWith: { first, _ in first }
    )
    var sections: [AlbumDiscSection] = []
    for song in songs {
      let number = max(1, song.discNumber ?? 1)
      if sections.last?.number == number {
        sections[sections.count - 1].songs.append(song)
      } else {
        sections.append(
          AlbumDiscSection(
            number: number,
            subtitle: subtitles[number]?.nonEmptyValue ?? song.discSubtitle?.nonEmptyValue,
            songs: [song]
          )
        )
      }
    }
    return sections
  }

  var showsDiscHeadings: Bool {
    let sections = discSections
    return sections.count > 1 || sections.contains { $0.subtitle != nil }
  }
}

struct AlbumDiscSection: Identifiable, Hashable, Sendable {
  let number: Int
  let subtitle: String?
  var songs: [RemoteSong]

  var id: Int { number }
  var durationSeconds: Int { songs.reduce(0) { $0 + ($1.duration ?? 0) } }
}

struct ArtistPage: Hashable, Sendable {
  let artist: RemoteArtist
  let albums: [RemoteAlbum]
}

struct LibrarySearchResults: Hashable, Sendable {
  let artists: [RemoteArtist]
  let albums: [RemoteAlbum]
  let songs: [RemoteSong]

  static let empty = LibrarySearchResults(artists: [], albums: [], songs: [])

  var isEmpty: Bool {
    artists.isEmpty && albums.isEmpty && songs.isEmpty
  }
}

enum AlbumCollectionKind: String, CaseIterable, Hashable, Sendable {
  case recentlyAdded
  case recentReleases
  case topRated
  case mostPlayed
  case recentlyPlayed
  case alphabetical

  var title: String {
    switch self {
    case .recentlyAdded: "Recently Added"
    case .recentReleases: "Recent Releases"
    case .topRated: "Top Rated"
    case .mostPlayed: "Most Played"
    case .recentlyPlayed: "Recently Played"
    case .alphabetical: "Albums"
    }
  }

  var sortTitle: String {
    switch self {
    case .alphabetical: "Title"
    default: title
    }
  }

  var apiValue: String {
    switch self {
    case .recentlyAdded: "newest"
    case .recentReleases: "byYear"
    case .topRated: "highest"
    case .mostPlayed: "frequent"
    case .recentlyPlayed: "recent"
    case .alphabetical: "alphabeticalByName"
    }
  }
}

enum ArtistCollectionKind: String, CaseIterable, Hashable, Sendable {
  case recentlyAdded
  case alphabetical

  var title: String {
    switch self {
    case .recentlyAdded: "Recently Added Artists"
    case .alphabetical: "Artists"
    }
  }

  var sortTitle: String {
    switch self {
    case .recentlyAdded: "Recently Added"
    case .alphabetical: "Name"
    }
  }
}

extension QueueEntry {
  static func remoteSong(
    _ song: RemoteSong,
    streamURL: URL,
    artworkURL: URL?,
    nowPlayingArtworkURL: URL?,
    queueGroupID: UUID? = nil
  ) -> QueueEntry {
    QueueEntry(
      sourceID: song.id,
      url: streamURL,
      artworkURL: artworkURL,
      nowPlayingArtworkURL: nowPlayingArtworkURL,
      title: song.title,
      artist: song.artistName,
      album: song.albumName,
      albumID: song.albumId,
      queueGroupID: queueGroupID,
      year: song.year,
      trackNumber: song.track,
      discNumber: song.discNumber,
      discSubtitle: song.discSubtitle,
      durationSeconds: song.duration ?? 0,
      formatDescription: song.technicalSummary
    )
  }
}

private extension String {
  var nonEmptyValue: String? { isEmpty ? nil : self }
}
