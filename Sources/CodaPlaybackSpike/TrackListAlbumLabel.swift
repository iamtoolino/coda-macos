import SwiftUI

/// Shared header contents. Each surface owns its sizing context, gestures, and collection actions.
struct TrackListAlbumLabel: View {
  let artworkURL: URL?
  let title: String
  let artist: String
  let detail: String
  var compact = false

  var body: some View {
    HStack(spacing: compact ? 10 : 12) {
      ArtworkImage(url: artworkURL, cornerRadius: compact ? 6 : 8)
        .frame(width: compact ? 48 : 62, height: compact ? 48 : 62)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(compact ? .subheadline.weight(.semibold) : .headline)
          .lineLimit(compact ? 1 : nil)
        Text(artist)
          .font(compact ? .caption : .body)
          .foregroundStyle(.secondary)
          .lineLimit(compact ? 1 : nil)
        Text(detail)
          .font((compact ? Font.caption2 : Font.caption).monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: compact ? 0 : nil)
    }
  }
}
