import AppKit
import Darwin
import SwiftUI

@main
struct CodaPlaybackSpikeApp: App {
  @NSApplicationDelegateAdaptor(CodaAppDelegate.self) private var appDelegate
  @StateObject private var session: AppSession
  @StateObject private var player: PlayerController
  @StateObject private var artworkTreatments: ArtworkTreatmentSettings
  @StateObject private var queueHandoff: QueueHandoffCoordinator
  @StateObject private var scrobbler: ScrobbleCoordinator
  @StateObject private var playlistSaver = QueuePlaylistSaveCoordinator()

  init() {
    if CommandLine.arguments.contains("--self-test") {
      exit(SelfTests.run() ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    let isPlaybackTest = CommandLine.arguments.contains("--mpv-local-transition-test")
      || CommandLine.arguments.contains("--mpv-stream-test")
    let session = AppSession(loadCredentials: !isPlaybackTest)
    let player = PlayerController()
    _session = StateObject(wrappedValue: session)
    _player = StateObject(wrappedValue: player)
    _artworkTreatments = StateObject(wrappedValue: ArtworkTreatmentSettings())
    let queueHandoff = QueueHandoffCoordinator(session: session, player: player)
    _queueHandoff = StateObject(wrappedValue: queueHandoff)
    _scrobbler = StateObject(
      wrappedValue: ScrobbleCoordinator(session: session, player: player)
    )
    appDelegate.session = session
    appDelegate.queueHandoff = queueHandoff
  }

  var body: some Scene {
    WindowGroup("Coda") {
      ContentView()
        .environmentObject(session)
        .environmentObject(player)
        .environmentObject(artworkTreatments)
        .environmentObject(queueHandoff)
        .environmentObject(playlistSaver)
    }
    .defaultSize(width: 1_440, height: 900)
    .defaultLaunchBehavior(.presented)
    .commands {
      CodaStatusCommands()
      CodaRefreshCommands()
      CodaPlaylistCommands(
        session: session,
        player: player,
        playlistSaver: playlistSaver,
        artworkTreatments: artworkTreatments
      )

      CommandGroup(after: .toolbar) {
        Toggle(
          "Show Album Rating Badges",
          isOn: $artworkTreatments.showsAlbumRatingLabels
        )
      }

      CommandMenu("Library") {
        Button("Back") {
          session.goBack()
        }
        .keyboardShortcut("[", modifiers: [.command])
        .disabled(session.path.isEmpty)

        Divider()

        Button("Search") {
          session.selectRoot(.search)
        }
        .keyboardShortcut("f", modifiers: [.command])
      }

      CommandMenu("Playback") {
        Button(player.isPlaying ? "Pause" : "Play") {
          player.togglePlayback()
        }
        .keyboardShortcut(.space, modifiers: [])
        .disabled(player.currentEntry == nil)

        Divider()

        Button("Previous Track") { player.previous() }
          .keyboardShortcut(.leftArrow, modifiers: [.command])
          .disabled(!player.canGoPrevious)
        Button("Next Track") { player.next() }
          .keyboardShortcut(.rightArrow, modifiers: [.command])
          .disabled(!player.canGoNext)
      }
    }

    Window("Coda Status", id: "coda-status") {
      CodaStatusView()
        .environmentObject(session)
        .environmentObject(player)
    }
    .defaultSize(width: 540, height: 620)
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
  }
}

private struct CodaPlaylistCommands: Commands {
  @ObservedObject var session: AppSession
  @ObservedObject var player: PlayerController
  @ObservedObject var playlistSaver: QueuePlaylistSaveCoordinator
  @ObservedObject var artworkTreatments: ArtworkTreatmentSettings

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Save Queue as Playlist…") {
        if let client = session.client {
          playlistSaver.present(
            client: client,
            queue: player.queue,
            accent: artworkTreatments.accent
          )
        }
      }
      .keyboardShortcut("s", modifiers: [.command])
      .disabled(
        player.queue.isEmpty
          || session.client == nil
          || !session.hasEstablishedConnection
      )
    }
  }
}

struct CodaRefreshAction {
  let perform: @MainActor () -> Void
}

private struct CodaRefreshActionKey: FocusedValueKey {
  typealias Value = CodaRefreshAction
}

extension FocusedValues {
  var codaRefreshAction: CodaRefreshAction? {
    get { self[CodaRefreshActionKey.self] }
    set { self[CodaRefreshActionKey.self] = newValue }
  }
}

private struct CodaRefreshCommands: Commands {
  @FocusedValue(\.codaRefreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Refresh") {
        refreshAction?.perform()
      }
      .keyboardShortcut("r", modifiers: [.command])
      .disabled(refreshAction == nil)

      Divider()
    }
  }
}

@MainActor
private final class CodaAppDelegate: NSObject, NSApplicationDelegate {
  weak var session: AppSession?
  weak var queueHandoff: QueueHandoffCoordinator?
  private var terminationSignalSource: DispatchSourceSignal?
  private var mouseNavigationMonitor: Any?
  private var windowActivationObserver: NSObjectProtocol?
  private var isPreparingToTerminate = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
    NSApp.appearance = NSAppearance(named: .darkAqua)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--mpv-local-transition-test") {
      Task {
        let success = await SelfTests.runMPVLocalTransitionTest()
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
      }
      return
    }

    if CommandLine.arguments.contains("--mpv-stream-test") {
      Task {
        let success = await SelfTests.runMPVStreamTest()
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
      }
      return
    }

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    installMouseNavigationMonitor()
    installWindowActivationObserver()
    installGracefulTerminationSignalHandler()
    DispatchQueue.main.async { self.configureWindows() }
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let mouseNavigationMonitor {
      NSEvent.removeMonitor(mouseNavigationMonitor)
      self.mouseNavigationMonitor = nil
    }
    if let windowActivationObserver {
      NotificationCenter.default.removeObserver(windowActivationObserver)
      self.windowActivationObserver = nil
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isPreparingToTerminate, let queueHandoff else { return .terminateNow }
    isPreparingToTerminate = true
    Task { @MainActor in
      await queueHandoff.saveBeforeTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    configureWindows()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    DispatchQueue.main.async { self.configureWindows() }
    return true
  }

  private func installGracefulTerminationSignalHandler() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
      NSApp.terminate(nil)
    }
    source.resume()
    terminationSignalSource = source
  }

  private func installMouseNavigationMonitor() {
    guard mouseNavigationMonitor == nil else { return }
    mouseNavigationMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.swipe, .otherMouseDown]
    ) { [weak self] event in
      guard let self,
        NSApp.isActive,
        event.window === NSApp.keyWindow,
        event.window?.title != "Coda Status"
      else { return event }

      let isBackEvent =
        (event.type == .swipe && event.deltaX > 0)
        || (event.type == .otherMouseDown && event.buttonNumber == 3)
      guard isBackEvent, self.session?.goBack() == true else { return event }
      return nil
    }
  }

  private func installWindowActivationObserver() {
    guard windowActivationObserver == nil else { return }
    windowActivationObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      DispatchQueue.main.async {
        self?.configure(window)
      }
    }
  }

  private func configureWindows() {
    for window in NSApp.windows {
      configure(window)
    }
  }

  private func configure(_ window: NSWindow) {
    window.tabbingMode = .disallowed
    if window.title == "Coda Status" {
      window.styleMask.remove(.fullSizeContentView)
      window.titlebarAppearsTransparent = false
      window.titleVisibility = .visible
      window.titlebarSeparatorStyle = .automatic
      window.isOpaque = true
      window.backgroundColor = .windowBackgroundColor
      return
    }
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    window.toolbarStyle = .unified
    window.isOpaque = false
    window.backgroundColor = .clear
  }
}
