import AppKit
import SwiftUI

/// A lightning bolt that breathes via a Core Animation opacity animation.
///
/// SwiftUI redraws and re-lays-out the whole view tree for every frame of a continuous
/// animation, which costs ~10% CPU on this window while it sits idle. A CAAnimation runs on the
/// render server instead, so the main thread does nothing at all per frame.
///
/// Every bolt anchors its animation to the same point of the shared media clock (the last whole
/// multiple of the period), so all bolts are in the same phase and breathe in unison no matter
/// when they appeared, including a battery inserted long after launch.
struct BreathingBolt: NSViewRepresentable {
    var color: NSColor
    var breathing: Bool

    func makeNSView(context: Context) -> BoltView {
        let view = BoltView()
        view.configure(color: color, breathing: breathing)
        return view
    }

    func updateNSView(_ view: BoltView, context: Context) {
        view.configure(color: color, breathing: breathing)
    }
}

final class BoltView: NSView {
    /// Full cycle (fade down and back up).
    static let period: CFTimeInterval = 2.4
    private static let animationKey = "breath"

    private var color: NSColor?
    private var breathing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Purely decorative: let clicks fall through to the slot underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, breathing: Bool) {
        if color != self.color {
            self.color = color
            renderImage()
        }
        if breathing != self.breathing || (breathing && layer?.animation(forKey: Self.animationKey) == nil) {
            self.breathing = breathing
            applyAnimation()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderImage()
        // Core Animation drops animations when a layer leaves the window.
        applyAnimation()
    }

    private func renderImage() {
        guard let color,
              let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        else { return }
        layer?.contents = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func applyAnimation() {
        guard let layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        layer.opacity = 1
        // A layer outside a window has no meaningful time base yet; viewDidMoveToWindow tries again.
        guard breathing, window != nil else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.4
        fade.duration = Self.period / 2
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Start at the most recent whole multiple of the period on the shared media clock, expressed
        // in this layer's time. Every bolt then sits at the same point of the breath at any instant,
        // including one that appears long after the others (a battery put in later).
        let now = CACurrentMediaTime()
        let phase = now.truncatingRemainder(dividingBy: Self.period)
        fade.beginTime = layer.convertTime(now, from: nil) - phase
        layer.add(fade, forKey: Self.animationKey)
    }
}
