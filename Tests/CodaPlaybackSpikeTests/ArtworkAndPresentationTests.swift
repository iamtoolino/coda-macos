import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Artwork and presentation")
@MainActor
struct ArtworkAndPresentationTests {
  @Test("artwork purposes use one browsing size and one Retina presentation size")
  func artworkPurposesUseOneBrowsingSizeAndOneRetinaPresentationSize() throws {
    let passed = try { () throws -> Bool in
      ArtworkPurpose.standard.rawValue == 500
        && ArtworkPurpose.nowPlaying.rawValue == 1_200
    }()
    #expect(passed)
  }

  @Test("artwork invalidation advances the shared cache generation")
  func artworkInvalidationAdvancesTheSharedCacheGeneration() async {
    let cache = ArtworkImageCache.shared
    let previousGeneration = cache.generation
    await cache.invalidateAll()
    #expect(cache.generation == previousGeneration + 1)
  }

  @Test("artwork disk keys exclude authenticated request details")
  func artworkDiskKeysExcludeAuthenticatedRequestDetails() async throws {
    let url = try #require(
      URL(
        string:
          "https://music.example.test/base/rest/getCoverArt?u=private-user&t=secret-token&s=secret-salt&id=ar-artist123_0&size=500"
      )
    )
    let key = try #require(ArtworkDiskCacheKey(url: url))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = ArtworkDiskCache(directoryURL: directory)
    let fileURL = try #require(await cache.fileURL(for: key))

    #expect(key.kind == .artist)
    #expect(key.account.count == 32)
    #expect(key.entity == NavidromeConfiguration.md5("artist123"))
    #expect(fileURL.lastPathComponent == "500.image")
    #expect(!fileURL.path.contains("private-user"))
    #expect(!fileURL.path.contains("secret-token"))
    #expect(!fileURL.path.contains("secret-salt"))
    #expect(!fileURL.path.contains("artist123"))
  }

  @Test("album artwork versions share one persistent entity slot")
  func albumArtworkVersionsShareOnePersistentEntitySlot() throws {
    let olderURL = try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=old&s=one&id=al-album123_abcd&size=500"
      )
    )
    let newerURL = try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=new&s=two&id=al-album123_bcde&size=500"
      )
    )

    #expect(ArtworkDiskCacheKey(url: olderURL) == ArtworkDiskCacheKey(url: newerURL))
  }

  @Test("artist and album IDs occupy separate cache namespaces")
  func artistAndAlbumIDsOccupySeparateCacheNamespaces() throws {
    let artistURL = try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=a&s=b&id=ar-shared_0&size=500"
      )
    )
    let albumURL = try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=c&s=d&id=al-shared_0&size=500"
      )
    )
    let artistKey = try #require(ArtworkDiskCacheKey(url: artistURL))
    let albumKey = try #require(ArtworkDiskCacheKey(url: albumURL))

    #expect(artistKey.kind == .artist)
    #expect(albumKey.kind == .album)
    #expect(artistKey.entity == albumKey.entity)
    #expect(artistKey != albumKey)
  }

  @Test("playlist artwork is not eligible for persistent caching")
  func playlistArtworkIsNotEligibleForPersistentCaching() throws {
    let url = try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=a&s=b&id=pl-playlist_0&size=500"
      )
    )
    #expect(ArtworkDiskCacheKey(url: url) == nil)
  }

  @Test("artwork bytes survive across disk cache instances")
  func artworkBytesSurviveAcrossDiskCacheInstances() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try #require(ArtworkDiskCacheKey(url: persistentArtworkTestURL(size: 500)))
    let data = try #require(testArtworkData())

    let writer = ArtworkDiskCache(directoryURL: directory)
    await writer.store(data, for: key)
    let reader = ArtworkDiskCache(directoryURL: directory)

    #expect(await reader.data(for: key) == data)
  }

  @Test("corrupt persistent artwork is discarded")
  func corruptPersistentArtworkIsDiscarded() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ArtworkDiskCache(directoryURL: directory)
    let key = try #require(ArtworkDiskCacheKey(url: persistentArtworkTestURL(size: 500)))
    let fileURL = try #require(await cache.fileURL(for: key))
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not an image".utf8).write(to: fileURL)

    #expect(await cache.data(for: key) == nil)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test("targeted removal clears every requested artwork size")
  func targetedRemovalClearsEveryRequestedArtworkSize() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ArtworkDiskCache(directoryURL: directory)
    let standardKey = try #require(
      ArtworkDiskCacheKey(url: persistentArtworkTestURL(size: 500)))
    let nowPlayingKey = try #require(
      ArtworkDiskCacheKey(url: persistentArtworkTestURL(size: 1_200)))
    let data = try #require(testArtworkData())
    await cache.store(data, for: standardKey)
    await cache.store(data, for: nowPlayingKey)
    let standardURL = try #require(await cache.fileURL(for: standardKey))
    let nowPlayingURL = try #require(await cache.fileURL(for: nowPlayingKey))

    await cache.remove([standardKey, nowPlayingKey])

    #expect(!FileManager.default.fileExists(atPath: standardURL.path))
    #expect(!FileManager.default.fileExists(atPath: nowPlayingURL.path))
  }

  @Test("Coda network sessions cannot write URL responses to disk")
  func codaNetworkSessionsCannotWriteURLResponsesToDisk() {
    #expect(CodaURLSessions.api.configuration.urlCache == nil)
    #expect(CodaURLSessions.artwork.configuration.urlCache == nil)
    #expect(CodaURLSessions.api.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(
      CodaURLSessions.artwork.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
  }

  @Test("queue entries keep browsing and now playing artwork separate")
  func queueEntriesKeepBrowsingAndNowPlayingArtworkSeparate() throws {
    let passed = try { () throws -> Bool in
      let browsingURL = URL(string: "https://example.test/cover?size=500")!
      let nowPlayingURL = URL(string: "https://example.test/cover?size=1200")!
      let entry = QueueEntry(
        sourceID: "song",
        url: URL(string: "https://example.test/song")!,
        artworkURL: browsingURL,
        nowPlayingArtworkURL: nowPlayingURL,
        title: "Song"
      )
      return entry.artworkURL == browsingURL
        && entry.nowPlayingArtworkURL == nowPlayingURL
    }()
    #expect(passed)
  }

  private func persistentArtworkTestURL(size: Int) throws -> URL {
    try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=token&s=salt&id=al-album123_abcd&size=\(size)"
      )
    )
  }

  private func testArtworkData() -> Data? {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
    image.unlockFocus()
    return image.tiffRepresentation
  }

  @Test("same album identity can repair stale artwork treatment")
  func sameAlbumIdentityCanRepairStaleArtworkTreatment() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let staleImage = NSImage(size: NSSize(width: 1, height: 1))
      let currentImage = NSImage(size: NSSize(width: 2, height: 2))
      let staleAccent = ArtworkColor(red: 0.7, green: 0.2, blue: 0.1)
      let currentAccent = ArtworkColor(red: 0.1, green: 0.6, blue: 0.9)

      treatments.rememberAlbumArtwork(staleImage, accent: staleAccent, identity: "album")
      treatments.applyDisplayContext(.album("album"))
      treatments.rememberAlbumArtwork(currentImage, accent: currentAccent, identity: "album")
      treatments.applyDisplayContext(.album("album"))

      return treatments.artwork === currentImage
        && treatments.accent == currentAccent
    }()
    #expect(passed)
  }

  @Test("remembering hidden playback artwork preserves displayed album")
  func rememberingHiddenPlaybackArtworkPreservesDisplayedAlbum() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let displayedImage = NSImage(size: NSSize(width: 1, height: 1))
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      let displayedAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.8)
      let playbackAccent = ArtworkColor(red: 0.8, green: 0.2, blue: 0.1)

      treatments.rememberAlbumArtwork(
        displayedImage,
        accent: displayedAccent,
        identity: "displayed"
      )
      treatments.applyDisplayContext(.album("displayed"))
      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: playbackAccent,
        identity: "playing"
      )

      guard treatments.artwork === displayedImage, treatments.accent == displayedAccent else {
        return false
      }

      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "playing")
      )
      return treatments.artwork === playbackImage
        && treatments.accent == playbackAccent
    }()
    #expect(passed)
  }

  @Test("non-album navigation centrally restores matching playback theme")
  func nonAlbumNavigationCentrallyRestoresMatchingPlaybackTheme() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      let albumImage = NSImage(size: NSSize(width: 3, height: 3))
      let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
      let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)

      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: playbackAccent,
        identity: "blue-playing"
      )
      treatments.rememberAlbumArtwork(
        albumImage,
        accent: albumAccent,
        identity: "red-album"
      )
      treatments.applyDisplayContext(.album("red-album"))
      guard treatments.artwork === albumImage else { return false }

      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "blue-playing")
      )
      return treatments.artwork === playbackImage
        && treatments.accent == playbackAccent
        && treatments.displayedIdentity == "blue-playing"
    }()
    #expect(passed)
  }

  @Test("pending themes hold the previous valid treatment")
  func pendingThemesHoldThePreviousValidTreatment() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: playbackAccent,
        identity: "playing"
      )
      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "playing")
      )
      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "stale")
      )
      guard treatments.artwork === playbackImage,
        treatments.accent == playbackAccent,
        treatments.displayedIdentity == "playing"
      else { return false }

      treatments.applyDisplayContext(
        .resolve(
          displayedAlbumID: nil,
          playbackIdentity: "playing"
        )
      )
      guard treatments.artwork === playbackImage, treatments.accent == playbackAccent else {
        return false
      }

      treatments.applyDisplayContext(.album("red-pending"))
      guard treatments.artwork === playbackImage else { return false }

      let albumImage = NSImage(size: NSSize(width: 3, height: 3))
      let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)
      treatments.rememberAlbumArtwork(
        albumImage,
        accent: albumAccent,
        identity: "red-pending"
      )
      treatments.applyDisplayContext(.album("red-pending"))
      return treatments.artwork === albumImage && treatments.accent == albumAccent
    }()
    #expect(passed)
  }

  @Test("empty playback context uses the static Coda brand theme")
  func emptyPlaybackContextUsesTheStaticCodaBrandTheme() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: ArtworkColor(red: 0.1, green: 0.3, blue: 0.9),
        identity: "playing"
      )
      treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
      treatments.applyDisplayContext(.standard(activePlaybackIdentity: nil))
      return treatments.artwork == nil
        && treatments.accent == .fallback
        && treatments.displayedIdentity == nil
    }()
    #expect(passed)
  }

  @Test("generated Coda cover extracts a warm accent")
  func generatedCodaCoverExtractsAWarmAccent() throws {
    let passed = try { () throws -> Bool in
      let accent = AlbumArtworkLoader.extractAccent(from: CodaPlaceholderArtwork.image)
      return accent.red > accent.green
        && accent.green > accent.blue
        && accent.red - accent.blue > 0.12
    }()
    #expect(passed)
  }

  @Test("pausing keeps an active now playing presentation visible")
  func pausingKeepsAnActiveNowPlayingPresentationVisible() throws {
    let passed = try { () throws -> Bool in
      let presentation = NowPlayingPresentationController()
      presentation.prepare(
        playbackKey: "album:playing",
        artwork: NSImage(size: NSSize(width: 2, height: 2)),
        accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
      )
      presentation.updateContext(
        window: nil,
        isApplicationActive: true,
        hasEstablishedConnection: true,
        playbackKey: "album:playing",
        isPlaying: true
      )
      presentation.present()
      guard presentation.isPresented else { return false }
      presentation.updateContext(
        window: nil,
        isApplicationActive: true,
        hasEstablishedConnection: true,
        playbackKey: "album:playing",
        isPlaying: false
      )
      return presentation.isPresented
    }()
    #expect(passed)
  }

  @Test("now playing automatic presentation preference persists")
  func nowPlayingAutomaticPresentationPreferencePersists() throws {
    let passed = try { () throws -> Bool in
      let suiteName = "CodaTests-NowPlaying-\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let presentation = NowPlayingPresentationController(defaults: defaults)
      guard presentation.automaticallyPresents else { return false }
      presentation.automaticallyPresents = false

      return !NowPlayingPresentationController(defaults: defaults).automaticallyPresents
    }()
    #expect(passed)
  }

  @Test("now playing preference migrates the experimental key")
  func nowPlayingPreferenceMigratesTheExperimentalKey() throws {
    let passed = try { () throws -> Bool in
      let suiteName = "CodaTests-NowPlayingMigration-\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
      defer { defaults.removePersistentDomain(forName: suiteName) }
      defaults.set(false, forKey: "automatically-shows-now-playing")

      let presentation = NowPlayingPresentationController(defaults: defaults)
      return !presentation.automaticallyPresents
        && defaults.object(forKey: "automatically-show-now-playing") as? Bool == false
        && defaults.object(forKey: "automatically-shows-now-playing") == nil
    }()
    #expect(passed)
  }

  @Test("manual now playing remains available when automatic presentation is off")
  func manualNowPlayingRemainsAvailableWhenAutomaticPresentationIsOff() throws {
    let passed = try { () throws -> Bool in
      let suiteName = "CodaTests-ManualNowPlaying-\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let presentation = NowPlayingPresentationController(defaults: defaults)
      presentation.automaticallyPresents = false
      presentation.prepare(
        playbackKey: "album:manual",
        artwork: NSImage(size: NSSize(width: 2, height: 2)),
        accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
      )
      presentation.updateContext(
        window: nil,
        isApplicationActive: true,
        hasEstablishedConnection: true,
        playbackKey: "album:manual",
        isPlaying: true
      )
      presentation.present()
      return presentation.isPresented
    }()
    #expect(passed)
  }

  @Test("inactive now playing delay caps remaining time")
  func inactiveNowPlayingDelayCapsRemainingTime() {
    #expect(NowPlayingAutomaticPresentationTiming.activeDelay == .seconds(60))
    #expect(NowPlayingAutomaticPresentationTiming.inactiveDelayCap == .seconds(15))
    #expect(
      NowPlayingAutomaticPresentationTiming.delayAfterBecomingInactive(
        remaining: .seconds(48)
      ) == .seconds(15)
    )
    #expect(
      NowPlayingAutomaticPresentationTiming.delayAfterBecomingInactive(
        remaining: .seconds(7)
      ) == .seconds(7)
    )
    #expect(
      NowPlayingAutomaticPresentationTiming.delayAfterBecomingInactive(
        remaining: nil
      ) == .seconds(15)
    )
  }

  @Test("album artwork overrides embedded track artwork")
  func albumArtworkOverridesEmbeddedTrackArtwork() throws {
    let passed = try { () throws -> Bool in
      let song = RemoteSong(
        id: "1",
        title: "Track",
        albumId: "album-artwork",
        coverArt: "embedded-track-artwork"
      )
      return song.albumArtworkID == "album-artwork"
    }()
    #expect(passed)
  }
}
