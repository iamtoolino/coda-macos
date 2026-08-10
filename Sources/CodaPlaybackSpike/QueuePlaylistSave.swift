import AppKit
import SwiftUI

@MainActor
final class QueuePlaylistSaveCoordinator: ObservableObject {
  enum Phase: Equatable {
    case checking
    case ready
    case saving
    case saved
    case failed(String)
  }

  @Published var isPresented = false
  @Published var name = ""
  @Published private(set) var phase: Phase = .ready
  @Published private(set) var playlists: [RemotePlaylist] = []

  private var client: NavidromeClient?
  private var songIDs: [String] = []
  private var task: Task<Void, Never>?

  var trackCount: Int { songIDs.count }

  var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var conflictingPlaylist: RemotePlaylist? {
    guard !trimmedName.isEmpty else { return nil }
    return playlists.first { isReplaceableMatch($0, name: trimmedName) }
  }

  var canSave: Bool {
    !trimmedName.isEmpty
      && phase != .checking
      && phase != .saving
      && phase != .saved
  }

  func present(
    client: NavidromeClient,
    queue: [QueueEntry]
  ) {
    guard !queue.isEmpty else { return }
    task?.cancel()
    self.client = client
    songIDs = queue.map(\.sourceID)
    name = Self.defaultPlaylistName()
    playlists = []
    phase = .checking
    isPresented = true
    loadPlaylists()
  }

  func loadPlaylists() {
    guard let client else { return }
    task?.cancel()
    phase = .checking
    task = Task { @MainActor [weak self] in
      do {
        let playlists = try await client.playlists()
        guard let self, !Task.isCancelled else { return }
        self.playlists = playlists
        self.phase = .ready
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.phase = .failed(error.localizedDescription)
      }
    }
  }

  func save() {
    guard let client, canSave else { return }
    let requestedName = trimmedName
    let requestedSongIDs = songIDs
    task?.cancel()
    phase = .saving
    task = Task { @MainActor [weak self] in
      do {
        let currentPlaylists = try await client.playlists()
        guard !Task.isCancelled else { return }
        let existing = currentPlaylists.first {
          self?.isReplaceableMatch($0, name: requestedName) == true
        }

        if let existing {
          let playlist = try await client.playlist(id: existing.id)
          try await client.replacePlaylist(
            id: existing.id,
            existingSongCount: playlist.songs.count,
            songIDs: requestedSongIDs
          )
        } else {
          try await client.createPlaylist(
            name: requestedName,
            songIDs: requestedSongIDs
          )
        }

        guard let self, !Task.isCancelled else { return }
        self.phase = .saved
        try? await Task.sleep(for: .milliseconds(850))
        guard !Task.isCancelled, self.phase == .saved else { return }
        self.dismiss()
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.phase = .failed(error.localizedDescription)
      }
    }
  }

  func dismiss() {
    task?.cancel()
    task = nil
    isPresented = false
  }

  private func isReplaceableMatch(_ playlist: RemotePlaylist, name: String) -> Bool {
    guard
      playlist.name.compare(name, options: .caseInsensitive) == .orderedSame
    else {
      return false
    }
    guard let owner = playlist.owner, let client else { return true }
    return owner.caseInsensitiveCompare(client.configuration.username) == .orderedSame
  }

  private static func defaultPlaylistName() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return "Queue \(formatter.string(from: Date()))"
  }
}

struct QueuePlaylistSaveSheet: View {
  @EnvironmentObject private var saver: QueuePlaylistSaveCoordinator
  @EnvironmentObject private var artworkTreatments: ArtworkTreatmentSettings
  @EnvironmentObject private var nowPlayingPresentation: NowPlayingPresentationController
  @FocusState private var nameFieldIsFocused: Bool

  var body: some View {
    VStack(spacing: 18) {
      if saver.phase == .saved {
        savedContent
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
      } else {
        formContent
          .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: saver.phase)
    .padding(28)
    .frame(width: 470)
    .background {
      ZStack {
        Color(nsColor: .windowBackgroundColor)
        RadialGradient(
          colors: [
            interfaceAccent.color.opacity(0.12),
            .clear,
          ],
          center: .topLeading,
          startRadius: 0,
          endRadius: 430
        )
      }
    }
    .interactiveDismissDisabled(saver.phase == .saving)
    .task {
      guard saver.phase != .saved else { return }
      nameFieldIsFocused = true
      try? await Task.sleep(for: .milliseconds(80))
      NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
  }

  private var formContent: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        Image(systemName: "music.note.list")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(.primary.opacity(0.82))
          .frame(width: 42, height: 42)

        VStack(alignment: .leading, spacing: 2) {
          Text("Save Queue as Playlist")
            .font(.title2.weight(.semibold))
          Text("\(saver.trackCount) \(saver.trackCount == 1 ? "track" : "tracks")")
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Playlist Name")
          .font(.subheadline.weight(.medium))
        TextField("Playlist name", text: $saver.name)
          .textFieldStyle(.plain)
          .padding(.horizontal, 9)
          .frame(height: 30)
          .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(Color.black.opacity(0.18))
          }
          .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(
                nameFieldIsFocused
                  ? interfaceAccent.color
                  : Color.primary.opacity(0.12),
                lineWidth: nameFieldIsFocused ? 2 : 1
              )
          }
          .tint(interfaceAccent.color)
          .accentColor(interfaceAccent.color)
          .focused($nameFieldIsFocused)
          .disabled(isBusy)
          .onSubmit {
            if saver.canSave {
              saver.save()
            }
          }
        status
          .frame(minHeight: 20, alignment: .leading)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          saver.dismiss()
        }
        .buttonStyle(NeutralDialogButtonStyle())
        .keyboardShortcut(.cancelAction)
        .disabled(isBusy)

        Button(primaryButtonTitle) {
          saver.save()
        }
        .buttonStyle(
          PrimaryDialogButtonStyle(
            background: interfaceAccent.color,
            foreground: interfaceAccent.contrastingColor
          )
        )
        .keyboardShortcut(.defaultAction)
        .disabled(!saver.canSave)
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    switch saver.phase {
    case .checking:
      Label {
        Text("Checking Navidrome…")
      } icon: {
        ProgressView()
          .controlSize(.small)
          .tint(interfaceAccent.color)
      }
      .foregroundStyle(.secondary)
    case .ready:
      if let playlist = saver.conflictingPlaylist {
        Label(
          "A playlist named “\(playlist.name)” already exists. Replace its \(playlist.songCount ?? 0) tracks?",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.primary.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
      } else if saver.trimmedName.isEmpty {
        Label("Enter a playlist name.", systemImage: "text.cursor")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle")
          Text("A new playlist will be created.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    case .saving:
      Label {
        Text(saver.conflictingPlaylist == nil ? "Saving playlist…" : "Replacing playlist…")
      } icon: {
        ProgressView()
          .controlSize(.small)
          .tint(interfaceAccent.color)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    case .saved:
      EmptyView()
    }
  }

  private var savedContent: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 42, weight: .medium))
        .foregroundStyle(interfaceAccent.color)
      Text("Playlist Saved")
        .font(.title2.weight(.semibold))
      Text("“\(saver.trimmedName)” was saved to Navidrome.")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 150)
  }

  private var primaryButtonTitle: String {
    saver.conflictingPlaylist == nil ? "Save" : "Replace"
  }

  private var isBusy: Bool {
    saver.phase == .saving || saver.phase == .saved
  }

  private var interfaceAccent: ArtworkColor {
    nowPlayingPresentation.resolvedAccent(artworkTreatments.accent)
  }
}

private struct NeutralDialogButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.medium))
      .foregroundStyle(.primary.opacity(isEnabled ? 0.9 : 0.4))
      .padding(.horizontal, 16)
      .padding(.vertical, 7)
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(
            Color.primary.opacity(
              configuration.isPressed ? 0.15 : 0.08
            )
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

private struct PrimaryDialogButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let background: Color
  let foreground: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.medium))
      .foregroundStyle(foreground.opacity(isEnabled ? 1 : 0.55))
      .padding(.horizontal, 16)
      .padding(.vertical, 7)
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(
            background.opacity(
              isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.3
            )
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}
