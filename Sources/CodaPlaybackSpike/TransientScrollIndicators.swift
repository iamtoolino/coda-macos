import AppKit
import SwiftUI

/// Applies transient overlay scrollers to the nearest containing `NSScrollView` without changing
/// the application's or user's global scrollbar preference.
struct TransientScrollIndicators: NSViewRepresentable {
  @MainActor
  final class Coordinator: NSObject {
    private weak var scrollView: NSScrollView?
    private var originalStyle: NSScroller.Style?
    private var originallyAutohidScrollers: Bool?

    override init() {
      super.init()
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(preferredScrollerStyleDidChange),
        name: NSScroller.preferredScrollerStyleDidChangeNotification,
        object: nil
      )
    }

    func attach(to candidate: NSScrollView?) {
      guard let candidate else { return }
      if scrollView !== candidate {
        restoreScrollView()
        scrollView = candidate
        originalStyle = candidate.scrollerStyle
        originallyAutohidScrollers = candidate.autohidesScrollers
      }

      applyTransientStyle()
    }

    func restore() {
      NSObject.cancelPreviousPerformRequests(
        withTarget: self,
        selector: #selector(reapplyTransientStyle),
        object: nil
      )
      NotificationCenter.default.removeObserver(self)
      restoreScrollView()
    }

    private func restoreScrollView() {
      if let originalStyle {
        scrollView?.scrollerStyle = originalStyle
      }
      if let originallyAutohidScrollers {
        scrollView?.autohidesScrollers = originallyAutohidScrollers
      }
      scrollView = nil
      originalStyle = nil
      originallyAutohidScrollers = nil
    }

    private func applyTransientStyle() {
      guard let scrollView else { return }
      if scrollView.scrollerStyle != .overlay {
        scrollView.scrollerStyle = .overlay
      }
      if !scrollView.autohidesScrollers {
        scrollView.autohidesScrollers = true
      }
    }

    @objc private func preferredScrollerStyleDidChange() {
      // AppKit also updates every NSScrollView in response to this notification. Reapply on the
      // next run-loop turn so our album-only override wins regardless of observer ordering.
      perform(#selector(reapplyTransientStyle), with: nil, afterDelay: 0)
    }

    @objc private func reapplyTransientStyle() {
      applyTransientStyle()
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> ScrollViewProbe {
    let probe = ScrollViewProbe()
    probe.onContainingScrollViewChange = { [weak coordinator = context.coordinator] scrollView in
      coordinator?.attach(to: scrollView)
    }
    return probe
  }

  func updateNSView(_ nsView: ScrollViewProbe, context: Context) {
    context.coordinator.attach(to: nsView.enclosingScrollView)
  }

  static func dismantleNSView(_ nsView: ScrollViewProbe, coordinator: Coordinator) {
    nsView.onContainingScrollViewChange = nil
    coordinator.restore()
  }
}

final class ScrollViewProbe: NSView {
  var onContainingScrollViewChange: ((NSScrollView?) -> Void)?

  override func layout() {
    super.layout()
    // SwiftUI can re-tile or replace the containing scroll view during responsive layout changes.
    // This only verifies the native settings; it does not implement custom indicator behavior.
    onContainingScrollViewChange?(enclosingScrollView)
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    onContainingScrollViewChange?(enclosingScrollView)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onContainingScrollViewChange?(enclosingScrollView)
  }
}
