import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Artist credits")
struct ArtistCreditTests {
  @Test("display punctuation remains unlinked and identities do not depend on order")
  func separateLinks() {
    let credit = ArtistCredit(name: "Alice & Bob", artists: [
      RemoteArtistReference(id: "bob", name: "Bob"),
      RemoteArtistReference(id: "alice", name: "Alice"),
    ])
    #expect(credit.segments == [
      .init(text: "Alice", artistID: "alice"),
      .init(text: " & ", artistID: nil),
      .init(text: "Bob", artistID: "bob"),
    ])
  }

  @Test("combined identities and aliases are not guessed from punctuation")
  func combinedAndAliasCredits() {
    let combined = ArtistCredit(name: "Alice & Bob", artists: [
      RemoteArtistReference(id: "combined", name: "Alice & Bob")])
    #expect(combined.segments == [.init(text: "Alice & Bob", artistID: "combined")])
    let alias = ArtistCredit(name: "Original Credit", artists: [
      RemoteArtistReference(id: "canonical", name: "Canonical Artist")])
    #expect(alias.segments == [.init(text: "Original Credit", artistID: nil)])
    #expect(alias.unlinkedArtists.map(\.id) == ["canonical"])
    #expect(ArtistCredit(name: "Legacy", artists: [], legacyArtistID: "legacy").segments == [
      .init(text: "Legacy", artistID: "legacy")])
  }

  @Test("overlapping artist names prefer the longer identity")
  func overlappingNames() {
    let credit = ArtistCredit(name: "Alice Band feat. Alice", artists: [
      .init(id: "solo", name: "Alice"), .init(id: "band", name: "Alice Band")])
    #expect(credit.segments == [.init(text: "Alice Band", artistID: "band"),
      .init(text: " feat. ", artistID: nil), .init(text: "Alice", artistID: "solo")])
  }

  @Test("only explicit compilation metadata adds artists to track rows")
  func compilationRows() throws {
    let song = RemoteSong(id: "song", title: "Song", artist: "Performer",
                          displayAlbumArtist: "Various Artists", albumId: "album")
    let album = RemoteAlbum(id: "album", name: "Soundtrack", artist: "Various Artists",
                            isCompilation: true)
    let enriched = song.applyingAlbum(album)
    let entry = QueueEntry.remoteSong(enriched,
      streamURL: try #require(URL(string: "https://example.test/stream")),
      artworkURL: nil, nowPlayingArtworkURL: nil)
    #expect(entry.artist == "Performer")
    #expect(entry.albumArtistName == "Various Artists")
    #expect(entry.isCompilation == true)
  }

  @Test("album display credits and legacy song fallbacks decode independently")
  func fallbacks() throws {
    let album = try JSONDecoder().decode(RemoteAlbum.self, from: Data(
      #"{"id":"album","name":"Album","artist":"Legacy","displayArtist":"Alice & Bob","artists":[{"id":"a","name":"Alice"},{"id":"b","name":"Bob"}],"isCompilation":false}"#.utf8))
    #expect(album.artistName == "Alice & Bob")
    #expect(album.artistCredit.artists.count == 2)
    #expect(album.isCompilation == false)
    let song = RemoteSong(id: "song", title: "Song", artist: "Legacy", displayArtist: "")
    #expect(song.artistName == "Legacy")
    #expect(song.applyingAlbum(album).albumArtistName == "Alice & Bob")
    #expect(song.applyingAlbum(album).artistName == "Legacy")
  }

  @Test("album API carries compilation metadata and search hides zero-album artists only")
  func albumAPIAndSearch() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ArtistMetadataProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = NavidromeClient(configuration: try NavidromeConfiguration(
      server: "https://example.test", username: "test", password: "test"), session: session)
    let page = try await client.album(id: "album")
    #expect(page.album.artistName == "Album Credit")
    #expect(page.album.artistCredit.artists.map(\.id) == ["album-artist"])
    #expect(page.songs.first?.artistName == "Track Performer")
    #expect(page.songs.first?.albumArtistName == "Album Credit")
    #expect(page.songs.first?.isCompilation == true)
    let results = try await client.search("performer")
    #expect(results.artists.map(\.id) == ["album-artist", "legacy"])
    #expect(results.albums.map(\.id) == ["compilation"])
    #expect(results.songs.map(\.id) == ["compilation-track"])
  }

  @Test("queue album grouping remains stable when track performers differ")
  func queueAlbumGrouping() throws {
    let url = try #require(URL(string: "https://example.test/stream"))
    let entries = ["Alice", "Bob"].map { artist in
      QueueEntry.remoteSong(RemoteSong(id: artist, title: "Song", album: "Album", artist: artist,
        displayAlbumArtist: "Album Credit"), streamURL: url, artworkURL: nil, nowPlayingArtworkURL: nil)
    }
    let groups = queueGroups(entries)
    #expect(groups.count == 1)
    #expect(groups.first?.artist == "Album Credit")
    #expect(entries.map(\.artist) == ["Alice", "Bob"])
  }
}

private final class ArtistMetadataProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let body = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","album":{"id":"album","name":"Album","artist":"Legacy Credit","displayArtist":"Album Credit","artists":[{"id":"album-artist","name":"Album Credit"}],"isCompilation":true,"song":[{"id":"song","title":"Song","artist":"Track Performer"}]},"searchResult3":{"artist":[{"id":"album-artist","name":"Album Artist","albumCount":2},{"id":"performer","name":"Track Performer","albumCount":0},{"id":"legacy","name":"Legacy Artist"}],"album":[{"id":"compilation","name":"Soundtrack","artist":"Various Artists"}],"song":[{"id":"compilation-track","title":"Song","artist":"Track Performer"}]}}}"#.utf8)
    guard let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                     headerFields: ["Content-Type": "application/json"])
    else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
