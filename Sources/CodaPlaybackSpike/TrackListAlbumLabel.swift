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
        // Headers match standalone rows of the same list: same cover size, two lines.
        .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(compact ? .subheadline.weight(.semibold) : .headline)
          .lineLimit(1)
        Text([artist, detail].filter { !$0.isEmpty }.joined(separator: " · "))
          .font((compact ? Font.caption : Font.subheadline).monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: compact ? 0 : nil)
    }
  }
}
