import Foundation

@propertyWrapper
struct LossyReplayGain: Decodable, Hashable, Sendable {
  var wrappedValue: ReplayGainMetadata?

  init(wrappedValue: ReplayGainMetadata?) { self.wrappedValue = wrappedValue }

  init(from decoder: any Decoder) throws {
    wrappedValue = try? ReplayGainMetadata(from: decoder)
  }
}

extension KeyedDecodingContainer {
  func decode(_ type: LossyReplayGain.Type, forKey key: Key) throws -> LossyReplayGain {
    try decodeIfPresent(type, forKey: key) ?? LossyReplayGain(wrappedValue: nil)
  }
}

/// OpenSubsonic values describe the original recording. Invalid individual fields are absent,
/// rather than making an otherwise playable song fail decoding.
struct ReplayGainMetadata: Decodable, Hashable, Sendable {
  var trackGain: Double? = nil
  var albumGain: Double? = nil
  var trackPeak: Double? = nil
  var albumPeak: Double? = nil

  init(trackGain: Double? = nil, albumGain: Double? = nil,
       trackPeak: Double? = nil, albumPeak: Double? = nil) {
    self.trackGain = trackGain
    self.albumGain = albumGain
    self.trackPeak = trackPeak
    self.albumPeak = albumPeak
  }

  private enum CodingKeys: String, CodingKey {
    case trackGain, albumGain, trackPeak, albumPeak
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    trackGain = try? values.decode(Double.self, forKey: .trackGain)
    albumGain = try? values.decode(Double.self, forKey: .albumGain)
    trackPeak = try? values.decode(Double.self, forKey: .trackPeak)
    albumPeak = try? values.decode(Double.self, forKey: .albumPeak)
  }
}

struct ReplayGainDecision {
  enum Source: String {
    case off = "Off", track = "Track", album = "Album", fallback = "Fallback"
  }

  let source: Source
  let requestedGainDb: Double
  let peak: Double?

  private var peakLimitedGainDb: Double {
    guard let peak, peak.isFinite, peak > 0 else { return requestedGainDb }
    return min(requestedGainDb, -20 * log10(peak))
  }

  var isPeakLimited: Bool { peakLimitedGainDb < requestedGainDb }

  var gainDb: Double {
    // mpv's constant gain path supports -150...150 dB. Normal tags are well inside this range.
    return min(150, max(-150, peakLimitedGainDb))
  }
}

enum ReplayGainPolicy {
  static let fallbackDb = -9.0

  static func gainDb(
    enabled: Bool, context: AlbumSequenceContext?, metadata: ReplayGainMetadata?
  ) -> Double {
    decision(enabled: enabled, context: context, metadata: metadata).gainDb
  }

  static func decision(
    enabled: Bool, context: AlbumSequenceContext?, metadata: ReplayGainMetadata?
  ) -> ReplayGainDecision {
    guard enabled else { return ReplayGainDecision(source: .off, requestedGainDb: 0, peak: nil) }
    let usesAlbum = context?.isAlbumSequence == true && metadata?.albumGain?.isFinite == true
    let gain = usesAlbum ? metadata?.albumGain : metadata?.trackGain
    let peak = usesAlbum ? metadata?.albumPeak : metadata?.trackPeak
    guard let gain, gain.isFinite else {
      return ReplayGainDecision(source: .fallback, requestedGainDb: fallbackDb, peak: nil)
    }
    return ReplayGainDecision(source: usesAlbum ? .album : .track, requestedGainDb: gain, peak: peak)
  }
}

struct PlaybackBackendItem: Equatable, Sendable {
  let url: URL
  var replayGainDb: Double = 0
}
