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

  @Test("artwork uses a dedicated modest Foundation response cache")
  func artworkUsesDedicatedModestFoundationResponseCache() {
    let cache = CodaURLSessions.artworkCache

    #expect(cache !== URLCache.shared)
    #expect(cache.memoryCapacity == ArtworkURLCachePolicy.memoryCapacity)
    #expect(cache.diskCapacity == ArtworkURLCachePolicy.diskCapacity)
    #expect(cache.memoryCapacity == 64 * 1_024 * 1_024)
    #expect(cache.diskCapacity == 500 * 1_024 * 1_024)
    #expect(CodaURLSessions.artwork.configuration.urlCache === cache)
  }

  @Test("artwork cache freshness follows the server cache policy")
  func artworkCacheFreshnessFollowsTheServerCachePolicy() throws {
    let url = try #require(URL(string: "https://music.example.test/cover?size=500"))
    let request = ArtworkURLCachePolicy.request(for: url)

    #expect(ArtworkURLCachePolicy.requestCachePolicy == .useProtocolCachePolicy)
    #expect(request.cachePolicy == .useProtocolCachePolicy)
    #expect(CodaURLSessions.artwork.configuration.requestCachePolicy == .useProtocolCachePolicy)
  }

  @Test("API requests remain ephemeral and uncached")
  func apiRequestsRemainEphemeralAndUncached() {
    #expect(CodaURLSessions.api.configuration.urlCache == nil)
    #expect(CodaURLSessions.api.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
  }

  @Test("targeted artwork refresh preserves unrelated cached responses")
  func targetedArtworkRefreshPreservesUnrelatedCachedResponses() async throws {
    let responseCache = URLCache(memoryCapacity: 1 * 1_024 * 1_024, diskCapacity: 0)
    let cache = ArtworkImageCache(
      responseCache: responseCache,
      session: ArtworkURLCachePolicy.makeSession(cache: responseCache)
    )
    let refreshedURL = try #require(URL(string: "https://music.example.test/refreshed?size=500"))
    let retainedURL = try #require(URL(string: "https://music.example.test/retained?size=500"))
    let refreshedRequest = ArtworkURLCachePolicy.request(for: refreshedURL)
    let retainedRequest = ArtworkURLCachePolicy.request(for: retainedURL)
    let response = try #require(
      HTTPURLResponse(
        url: refreshedURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Cache-Control": "max-age=3600"]
      )
    )
    responseCache.storeCachedResponse(
      CachedURLResponse(response: response, data: Data("refreshed".utf8)),
      for: refreshedRequest
    )
    let retainedResponse = try #require(
      HTTPURLResponse(
        url: retainedURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Cache-Control": "max-age=3600"]
      )
    )
    responseCache.storeCachedResponse(
      CachedURLResponse(response: retainedResponse, data: Data("retained".utf8)),
      for: retainedRequest
    )
    let previousGeneration = cache.generation

    await cache.invalidate(urls: [refreshedURL])

    #expect(cache.generation == previousGeneration + 1)
    #expect(responseCache.cachedResponse(for: refreshedRequest) == nil)
    #expect(responseCache.cachedResponse(for: retainedRequest)?.data == Data("retained".utf8))
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
    let browsingParameters = try #require(
      URLComponents(url: browsingURL, resolvingAgainstBaseURL: false)?.queryItems
    )
    let nowPlayingParameters = try #require(
      URLComponents(url: nowPlayingURL, resolvingAgainstBaseURL: false)?.queryItems
    )

    #expect(browsingParameters.first(where: { $0.name == "id" })?.value == resolvedID)
    #expect(nowPlayingParameters.first(where: { $0.name == "id" })?.value == resolvedID)
    #expect(browsingParameters.first(where: { $0.name == "size" })?.value == "500")
    #expect(nowPlayingParameters.first(where: { $0.name == "size" })?.value == "1200")
  }
}
