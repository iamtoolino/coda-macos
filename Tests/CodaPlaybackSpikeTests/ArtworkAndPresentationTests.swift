import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Artwork and presentation")
@MainActor
struct ArtworkAndPresentationTests {
  @Test("collection hero metrics preserve narrow and wide layouts")
  func collectionHeroMetricsPreserveNarrowAndWideLayouts() {
    let narrow = CollectionHeroMetrics(width: 430)
    #expect(narrow.artworkSize == 188)
    #expect(narrow.spacing == 18)
    #expect(narrow.trailingPadding == 20)
    #expect(narrow.height == 240)

    let wide = CollectionHeroMetrics(width: 900)
    #expect(wide.artworkSize == 236)
    #expect(wide.spacing == 26)
    #expect(wide.trailingPadding == 42)
    #expect(wide.height == 288)
  }

  @Test("artwork purposes use one browsing size and one Retina presentation size")
  func artworkPurposesUseOneBrowsingSizeAndOneRetinaPresentationSize() {
    #expect(ArtworkPurpose.standard.rawValue == 500)
    #expect(ArtworkPurpose.nowPlaying.rawValue == 1_200)
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
    #expect(key.variant == .browsing500)
    #expect(key.account.count == 32)
    #expect(key.entity == NavidromeConfiguration.md5("artist123"))
    #expect(fileURL.lastPathComponent == "500.image")
    #expect(!fileURL.path.contains("private-user"))
    #expect(!fileURL.path.contains("secret-token"))
    #expect(!fileURL.path.contains("secret-salt"))
    #expect(!fileURL.path.contains("artist123"))
  }

  @Test("original artwork requests omit only the server resize parameter")
  func originalArtworkRequestsOmitOnlyTheServerResizeParameter() throws {
    let sizedURL = try persistentArtworkTestURL(size: 500)
    let originalURL = try #require(ArtworkDiskCacheKey.originalRequestURL(from: sizedURL))
    let components = try #require(
      URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
    )
    let parameters = Dictionary(
      try #require(components.queryItems)
        .map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { first, _ in first }
    )

    #expect(parameters["size"] == nil)
    #expect(parameters["id"] == "al-album123_abcd")
    #expect(parameters["u"] == "user")
    #expect(parameters["t"] == "token")
    #expect(parameters["s"] == "salt")
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

  @Test("raw and typed album artwork IDs share persistent cache slots")
  func rawAndTypedAlbumArtworkIDsSharePersistentCacheSlots() throws {
    let rawBrowsingURL = try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=raw&s=one&id=album123&size=500"
      )
    )
    let typedBrowsingURL = try persistentArtworkTestURL(size: 500)
    let rawNowPlayingURL = try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=raw&s=two&id=album123&size=1200"
      )
    )
    let rawBrowsingKey = try #require(ArtworkDiskCacheKey(url: rawBrowsingURL))
    let typedBrowsingKey = try #require(ArtworkDiskCacheKey(url: typedBrowsingURL))
    let rawNowPlayingKey = try #require(ArtworkDiskCacheKey(url: rawNowPlayingURL))

    #expect(rawBrowsingKey.kind == .album)
    #expect(rawBrowsingKey == typedBrowsingKey)
    #expect(rawNowPlayingKey == typedBrowsingKey.withVariant(.original))
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

  @Test("original artwork creates a persistent local 500 pixel derivative")
  func originalArtworkCreatesAPersistentLocal500PixelDerivative() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let browsingKey = try #require(
      ArtworkDiskCacheKey(url: persistentArtworkTestURL(size: 500)))
    let originalKey = browsingKey.withVariant(.original)
    let originalData = try #require(testArtworkData(size: NSSize(width: 900, height: 600)))
    let cache = ArtworkDiskCache(directoryURL: directory)

    let browsingData = try #require(
      await cache.storeOriginalAndBrowsingImage(originalData, for: browsingKey)
    )
    let source = try #require(CGImageSourceCreateWithData(browsingData as CFData, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
    let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

    #expect(max(width, height) == 500)
    #expect(await cache.data(for: originalKey) == originalData)
    #expect(await cache.data(for: browsingKey) == browsingData)
    #expect(await cache.fileURL(for: originalKey)?.lastPathComponent == "original.image")
    #expect(await cache.fileURL(for: browsingKey)?.lastPathComponent == "500.image")
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

  @Test("targeted removal clears original and browsing artwork")
  func targetedRemovalClearsOriginalAndBrowsingArtwork() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ArtworkDiskCache(directoryURL: directory)
    let standardKey = try #require(
      ArtworkDiskCacheKey(url: persistentArtworkTestURL(size: 500)))
    let nowPlayingKey = try #require(
      ArtworkDiskCacheKey(url: persistentArtworkTestURL(size: 1_200)))
    let data = try #require(testArtworkData())
    _ = await cache.storeOriginalAndBrowsingImage(data, for: standardKey)
    let standardURL = try #require(await cache.fileURL(for: standardKey))
    let nowPlayingURL = try #require(await cache.fileURL(for: nowPlayingKey))

    await cache.remove([standardKey])

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
  func queueEntriesKeepBrowsingAndNowPlayingArtworkSeparate() {
    let browsingURL = URL(string: "https://example.test/cover?size=500")!
    let nowPlayingURL = URL(string: "https://example.test/cover?size=1200")!
    let entry = QueueEntry(
      sourceID: "song",
      url: URL(string: "https://example.test/song")!,
      artworkURL: browsingURL,
      nowPlayingArtworkURL: nowPlayingURL,
      title: "Song"
    )
    #expect(entry.artworkURL == browsingURL)
    #expect(entry.nowPlayingArtworkURL == nowPlayingURL)
  }

  private func persistentArtworkTestURL(size: Int) throws -> URL {
    try #require(
      URL(
        string:
          "https://music.example.test/rest/getCoverArt?u=user&t=token&s=salt&id=al-album123_abcd&size=\(size)"
      )
    )
  }

  private func testArtworkData(size: NSSize = NSSize(width: 2, height: 2)) -> Data? {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    return image.tiffRepresentation
  }

  @Test("same album identity can repair stale artwork treatment")
  func sameAlbumIdentityCanRepairStaleArtworkTreatment() {
    let treatments = ArtworkTreatmentSettings()
    let staleImage = NSImage(size: NSSize(width: 1, height: 1))
    let currentImage = NSImage(size: NSSize(width: 2, height: 2))
    let staleAccent = ArtworkColor(red: 0.7, green: 0.2, blue: 0.1)
    let currentAccent = ArtworkColor(red: 0.1, green: 0.6, blue: 0.9)

    treatments.rememberAlbumArtwork(staleImage, accent: staleAccent, identity: "album")
    treatments.applyDisplayContext(.album("album"))
    treatments.rememberAlbumArtwork(currentImage, accent: currentAccent, identity: "album")
    treatments.applyDisplayContext(.album("album"))

    #expect(treatments.artwork === currentImage)
    #expect(treatments.accent == currentAccent)
  }

  @Test("remembering hidden playback artwork preserves displayed album")
  func rememberingHiddenPlaybackArtworkPreservesDisplayedAlbum() {
    let treatments = ArtworkTreatmentSettings()
    let displayedImage = NSImage(size: NSSize(width: 1, height: 1))
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    let displayedAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.8)
    let playbackAccent = ArtworkColor(red: 0.8, green: 0.2, blue: 0.1)

    treatments.rememberAlbumArtwork(
      displayedImage, accent: displayedAccent, identity: "displayed")
    treatments.applyDisplayContext(.album("displayed"))
    treatments.rememberPlaybackArtwork(
      playbackImage, accent: playbackAccent, identity: "playing")

    #expect(treatments.artwork === displayedImage)
    #expect(treatments.accent == displayedAccent)

    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)
  }

  @Test("non-album navigation centrally restores matching playback theme")
  func nonAlbumNavigationCentrallyRestoresMatchingPlaybackTheme() {
    let treatments = ArtworkTreatmentSettings()
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    let albumImage = NSImage(size: NSSize(width: 3, height: 3))
    let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
    let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)

    treatments.rememberPlaybackArtwork(
      playbackImage, accent: playbackAccent, identity: "blue-playing")
    treatments.rememberAlbumArtwork(
      albumImage, accent: albumAccent, identity: "red-album")
    treatments.applyDisplayContext(.album("red-album"))
    #expect(treatments.artwork === albumImage)

    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "blue-playing"))
    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)
    #expect(treatments.displayedIdentity == "blue-playing")
  }

  @Test("pending themes hold the previous valid treatment")
  func pendingThemesHoldThePreviousValidTreatment() {
    let treatments = ArtworkTreatmentSettings()
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
    treatments.rememberPlaybackArtwork(
      playbackImage, accent: playbackAccent, identity: "playing")
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "stale"))

    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)
    #expect(treatments.displayedIdentity == "playing")

    treatments.applyDisplayContext(
      .resolve(
        hasEstablishedConnection: true,
        displayedAlbumID: nil,
        playbackIdentity: "playing"
      ))
    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)

    treatments.applyDisplayContext(.album("red-pending"))
    #expect(treatments.artwork === playbackImage)

    let albumImage = NSImage(size: NSSize(width: 3, height: 3))
    let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)
    treatments.rememberAlbumArtwork(
      albumImage, accent: albumAccent, identity: "red-pending")
    treatments.applyDisplayContext(.album("red-pending"))
    #expect(treatments.artwork === albumImage)
    #expect(treatments.accent == albumAccent)
  }

  @Test("late playback artwork cannot replace the disconnected brand theme")
  func latePlaybackArtworkCannotReplaceTheDisconnectedBrandTheme() {
    let treatments = ArtworkTreatmentSettings()
    let initialArtwork = NSImage(size: NSSize(width: 2, height: 2))
    let lateArtwork = NSImage(size: NSSize(width: 3, height: 3))

    treatments.rememberPlaybackArtwork(
      initialArtwork,
      accent: ArtworkColor(red: 0.2, green: 0.4, blue: 0.8),
      identity: "playing"
    )
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    treatments.applyDisplayContext(.brand)

    treatments.rememberPlaybackArtwork(
      lateArtwork,
      accent: ArtworkColor(red: 0.7, green: 0.2, blue: 0.1),
      identity: "playing"
    )
    treatments.applyDisplayContext(
      .resolve(
        hasEstablishedConnection: false,
        displayedAlbumID: nil,
        playbackIdentity: "playing"
      )
    )

    #expect(treatments.artwork == nil)
    #expect(treatments.accent == .fallback)
    #expect(treatments.displayedIdentity == nil)
  }

  @Test("empty playback context uses the static Coda brand theme")
  func emptyPlaybackContextUsesTheStaticCodaBrandTheme() {
    let treatments = ArtworkTreatmentSettings()
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    treatments.rememberPlaybackArtwork(
      playbackImage,
      accent: ArtworkColor(red: 0.1, green: 0.3, blue: 0.9),
      identity: "playing"
    )
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: nil))
    #expect(treatments.artwork == nil)
    #expect(treatments.accent == .fallback)
    #expect(treatments.displayedIdentity == nil)
  }

  @Test("generated Coda cover extracts a warm accent")
  func generatedCodaCoverExtractsAWarmAccent() {
    let accent = AlbumArtworkLoader.extractAccent(from: CodaPlaceholderArtwork.image)
    #expect(accent.red > accent.green)
    #expect(accent.green > accent.blue)
    #expect(accent.red - accent.blue > 0.12)
  }

  @Test("pausing keeps an active now playing presentation visible")
  func pausingKeepsAnActiveNowPlayingPresentationVisible() {
    let presentation = NowPlayingPresentationController()
    presentation.prepare(
      playbackKey: "album:playing",
      artwork: NSImage(size: NSSize(width: 2, height: 2)),
      accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
    )
    presentation.updateContext(
      window: nil, isApplicationActive: true, hasEstablishedConnection: true,
      playbackKey: "album:playing", isPlaying: true)
    presentation.present()
    #expect(presentation.isPresented)

    presentation.updateContext(
      window: nil, isApplicationActive: true, hasEstablishedConnection: true,
      playbackKey: "album:playing", isPlaying: false)
    #expect(presentation.isPresented)
  }

  @Test("now playing automatic presentation preference persists")
  func nowPlayingAutomaticPresentationPreferencePersists() throws {
    let suiteName = "CodaTests-NowPlaying-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let presentation = NowPlayingPresentationController(defaults: defaults)
    #expect(presentation.automaticallyPresents)
    presentation.automaticallyPresents = false
    #expect(!NowPlayingPresentationController(defaults: defaults).automaticallyPresents)
  }

  @Test("now playing preference migrates the experimental key")
  func nowPlayingPreferenceMigratesTheExperimentalKey() throws {
    let suiteName = "CodaTests-NowPlayingMigration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "automatically-shows-now-playing")

    let presentation = NowPlayingPresentationController(defaults: defaults)
    #expect(!presentation.automaticallyPresents)
    #expect(defaults.object(forKey: "automatically-show-now-playing") as? Bool == false)
    #expect(defaults.object(forKey: "automatically-shows-now-playing") == nil)
  }

  @Test("manual now playing remains available when automatic presentation is off")
  func manualNowPlayingRemainsAvailableWhenAutomaticPresentationIsOff() throws {
    let suiteName = "CodaTests-ManualNowPlaying-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let presentation = NowPlayingPresentationController(defaults: defaults)
    presentation.automaticallyPresents = false
    presentation.prepare(
      playbackKey: "album:manual",
      artwork: NSImage(size: NSSize(width: 2, height: 2)),
      accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
    )
    presentation.updateContext(
      window: nil, isApplicationActive: true, hasEstablishedConnection: true,
      playbackKey: "album:manual", isPlaying: true)
    presentation.present()
    #expect(presentation.isPresented)
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
  func albumArtworkOverridesEmbeddedTrackArtwork() {
    let song = RemoteSong(
      id: "1", title: "Track",
      albumId: "album-artwork", coverArt: "embedded-track-artwork")
    #expect(song.albumArtworkID == "album-artwork")
  }

  @Test("album artwork identity falls back to the album ID")
  func albumArtworkIdentityFallsBackToTheAlbumID() {
    #expect(
      RemoteAlbum(id: "album-id", name: "Album", coverArt: "canonical-artwork").artworkID
        == "canonical-artwork"
    )
    #expect(RemoteAlbum(id: "album-id", name: "Album").artworkID == "album-id")
  }

  @Test("canonical album artwork is preserved when songs enter the queue")
  func canonicalAlbumArtworkIsPreservedForQueueEntries() throws {
    let firstSong = RemoteSong(
      id: "1", title: "Track",
      albumId: "album-id", coverArt: "embedded-track-artwork")
    let secondSong = RemoteSong(
      id: "2", title: "Another Track",
      albumId: "another-album-id", coverArt: "another-embedded-artwork")

    #expect(
      AppSession.resolvedAlbumArtworkID(
        for: firstSong,
        canonicalAlbumArtworkID: "single-album-artwork",
        canonicalAlbumArtworkIDsBySongID: ["1": "mapped-album-artwork"]
      ) == "mapped-album-artwork"
    )
    #expect(
      AppSession.resolvedAlbumArtworkID(
        for: secondSong,
        canonicalAlbumArtworkID: "single-album-artwork",
        canonicalAlbumArtworkIDsBySongID: ["1": "mapped-album-artwork"]
      ) == "single-album-artwork"
    )
    #expect(
      AppSession.resolvedAlbumArtworkID(
        for: secondSong,
        canonicalAlbumArtworkID: nil,
        canonicalAlbumArtworkIDsBySongID: ["1": "mapped-album-artwork"]
      ) == "another-album-id"
    )

    let configuration = try NavidromeConfiguration(
      server: "https://music.example.test",
      username: "user",
      password: "password"
    )
    let resolvedID = try #require(
      AppSession.resolvedAlbumArtworkID(
        for: firstSong,
        canonicalAlbumArtworkID: nil,
        canonicalAlbumArtworkIDsBySongID: ["1": "al-album123_abcd"]
      )
    )
    let browsingURL = try configuration.coverArtURL(
      id: resolvedID,
      size: ArtworkPurpose.standard.rawValue,
      salt: "browsing"
    )
    let nowPlayingURL = try configuration.coverArtURL(
      id: resolvedID,
      size: ArtworkPurpose.nowPlaying.rawValue,
      salt: "now-playing"
    )
    let browsingKey = try #require(ArtworkDiskCacheKey(url: browsingURL))
    let nowPlayingKey = try #require(ArtworkDiskCacheKey(url: nowPlayingURL))

    #expect(browsingKey == nowPlayingKey.withVariant(.browsing500))
    #expect(nowPlayingKey == browsingKey.withVariant(.original))
  }
}
