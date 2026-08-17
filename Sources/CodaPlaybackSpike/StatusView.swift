import AppKit
import SwiftUI

struct CodaStatusView: View {
  @EnvironmentObject private var session: AppSession
  @EnvironmentObject private var player: PlayerController

  private let build = BuildIdentity.current

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header
      connectionSection
      buildSection

      HStack {
        if session.hasEstablishedConnection {
          Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
            Task {
              await session.signOut()
              player.clear()
            }
          }
        }
        Button("Copy Diagnostics", systemImage: "doc.on.doc") {
          copyDiagnostics()
        }
        Spacer()
        Button("Reconnect", systemImage: "arrow.clockwise") {
          Task { await session.connect() }
        }
        .disabled(session.connectionState == .connecting)
      }
      .buttonStyle(.bordered)
    }
    .padding(26)
    .frame(width: 540)
  }

  private var header: some View {
    HStack(spacing: 18) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 82, height: 82)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)

      VStack(alignment: .leading, spacing: 5) {
        Text("Coda")
          .font(.system(size: 30, weight: .bold, design: .rounded))
        Text("Version \(build.version) (\(build.bundleBuild))")
          .foregroundStyle(.secondary)
        Text(build.sourceBadge)
          .font(.system(.caption, design: .monospaced, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 9)
          .padding(.vertical, 4)
          .background(.quaternary, in: Capsule())
      }
      Spacer()
    }
  }

  private var connectionSection: some View {
    StatusSection(title: "Connection", systemImage: "network") {
      HStack(spacing: 10) {
        Circle()
          .fill(connectionColor)
          .frame(width: 9, height: 9)
          .shadow(color: connectionColor.opacity(0.45), radius: 4)
        VStack(alignment: .leading, spacing: 2) {
          Text(connectionTitle)
            .fontWeight(.semibold)
          if let connectionDetail {
            Text(connectionDetail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        Spacer()
      }

      if let configuration = session.configuration {
        StatusRow(label: "Server", value: configuration.serverURL.absoluteString)
        StatusRow(label: "Account", value: configuration.username)
        StatusRow(label: "Client", value: NavidromeConfiguration.clientName)
      }
      if let details = session.serverDetails {
        StatusRow(label: "Software", value: details.software ?? "Unknown")
        StatusRow(label: "Server version", value: details.version ?? "Unknown")
        StatusRow(label: "API version", value: details.apiVersion ?? "Unknown")
        StatusRow(
          label: "OpenSubsonic",
          value: details.supportsOpenSubsonic.map { $0 ? "Supported" : "Not advertised" }
            ?? "Unknown"
        )
      }
      StatusRow(label: "Playback engine", value: player.playbackEngineName)
    }
  }

  private var buildSection: some View {
    StatusSection(title: "Build", systemImage: "hammer") {
      StatusRow(label: "Git commit", value: build.commit, monospaced: true)
      if let tag = build.tag {
        StatusRow(label: "Git tag", value: tag, monospaced: true)
      }
      StatusRow(label: "Source", value: build.describe, monospaced: true)
      StatusRow(label: "Configuration", value: build.configuration)
      StatusRow(label: "Built", value: build.date)
    }
  }

  private var connectionTitle: String {
    switch session.connectionState {
    case .disconnected: "Disconnected"
    case .connecting: "Connecting…"
    case .connected: "Connected"
    case .failed: "Connection failed"
    }
  }

  private var connectionDetail: String? {
    switch session.connectionState {
    case .disconnected: "Coda is not connected to a server."
    case .connecting: "Checking the configured Navidrome server."
    case .connected(let host): host
    case .failed(let message): message
    }
  }

  private var connectionColor: Color {
    switch session.connectionState {
    case .connected: .green
    case .connecting: .orange
    case .disconnected, .failed: .red
    }
  }

  private func copyDiagnostics() {
    let serverHost = session.configuration?.serverURL.host ?? "not configured"
    let serverSoftware = session.serverDetails?.software ?? "unknown"
    let serverVersion = session.serverDetails?.version ?? "unknown"
    let diagnostics = """
      Coda \(build.version) (\(build.bundleBuild))
      Source: \(build.describe)
      Commit: \(build.commit)
      Configuration: \(build.configuration)
      Connection: \(connectionTitle)
      Server: \(serverHost)
      Server software: \(serverSoftware) \(serverVersion)
      Client: \(NavidromeConfiguration.clientName)
      Playback engine: \(player.playbackEngineName)
      """
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(diagnostics, forType: .string)
  }
}

private struct StatusSection<Content: View>: View {
  let title: String
  let systemImage: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(title, systemImage: systemImage)
        .font(.headline)
      content
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.separator.opacity(0.45), lineWidth: 0.6)
    }
  }
}

private struct StatusRow: View {
  let label: String
  let value: String
  var monospaced = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer(minLength: 20)
      Text(value)
        .font(monospaced ? .system(.body, design: .monospaced) : .body)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

private struct BuildIdentity {
  let version: String
  let bundleBuild: String
  let commit: String
  let tag: String?
  let describe: String
  let configuration: String
  let date: String

  static let current = BuildIdentity(bundle: .main)

  init(bundle: Bundle) {
    version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    bundleBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    commit = bundle.object(forInfoDictionaryKey: "CodaGitCommit") as? String ?? "Development"
    let stampedTag = bundle.object(forInfoDictionaryKey: "CodaGitTag") as? String
    tag = stampedTag?.isEmpty == false ? stampedTag : nil
    describe = bundle.object(forInfoDictionaryKey: "CodaGitDescribe") as? String ?? commit
    configuration =
      (bundle.object(forInfoDictionaryKey: "CodaBuildConfiguration") as? String)?.capitalized
      ?? "Development"
    date = bundle.object(forInfoDictionaryKey: "CodaBuildDate") as? String ?? "Unknown"
  }

  var sourceBadge: String {
    tag ?? describe
  }
}

struct CodaStatusCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Coda") {
        openWindow(id: "coda-status")
      }
    }
  }
}
