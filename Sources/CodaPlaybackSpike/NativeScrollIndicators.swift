import AppKit
import SwiftUI

/// Applies a native small control size to the nearest containing `NSScrollView`, optionally
/// keeping its indicators transient without changing the application-wide scrollbar preference.
struct NativeScrollIndicators: NSViewRepresentable {
  enum Visibility {
    case inherited
    case transient
  }

  var visibility: Visibility = .transient

  @MainActor
  final class Coordinator: NSObject {
    private let visibility: Visibility
    private weak var scrollView: NSScrollView?
    private var originalStyle: NSScroller.Style?
    private var originallyAutohidScrollers: Bool?
    private var originalVerticalControlSize: NSControl.ControlSize?
    private var originalHorizontalControlSize: NSControl.ControlSize?

    init(visibility: Visibility) {
      self.visibility = visibility
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
        originalVerticalControlSize = candidate.verticalScroller?.controlSize
        originalHorizontalControlSize = candidate.horizontalScroller?.controlSize
      }

      applyNativeStyle()
    }

    func restore() {
      NSObject.cancelPreviousPerformRequests(
        withTarget: self,
        selector: #selector(reapplyNativeStyle),
        object: nil
      )
      NotificationCenter.default.removeObserver(self)
      restoreScrollView()
    }

    private func restoreScrollView() {
      if visibility == .transient {
        if let originalStyle {
          scrollView?.scrollerStyle = originalStyle
        }
        if let originallyAutohidScrollers {
          scrollView?.autohidesScrollers = originallyAutohidScrollers
        }
      }
      if let originalVerticalControlSize {
        scrollView?.verticalScroller?.controlSize = originalVerticalControlSize
      }
      if let originalHorizontalControlSize {
        scrollView?.horizontalScroller?.controlSize = originalHorizontalControlSize
      }
      scrollView = nil
      originalStyle = nil
      originallyAutohidScrollers = nil
      originalVerticalControlSize = nil
      originalHorizontalControlSize = nil
    }

    private func applyNativeStyle() {
      guard let scrollView else { return }
      if visibility == .transient {
        if scrollView.scrollerStyle != .overlay {
          scrollView.scrollerStyle = .overlay
        }
        if !scrollView.autohidesScrollers {
          scrollView.autohidesScrollers = true
        }
      }
      if scrollView.verticalScroller?.controlSize != .small {
        scrollView.verticalScroller?.controlSize = .small
      }
      if scrollView.horizontalScroller?.controlSize != .small {
        scrollView.horizontalScroller?.controlSize = .small
      }
    }

    @objc private func preferredScrollerStyleDidChange() {
      // AppKit also updates every NSScrollView in response to this notification. Reapply on the
      // next run-loop turn so our local override wins regardless of observer ordering.
      perform(#selector(reapplyNativeStyle), with: nil, afterDelay: 0)
    }

    @objc private func reapplyNativeStyle() {
      applyNativeStyle()
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(visibility: visibility)
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
