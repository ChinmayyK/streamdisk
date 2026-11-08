import AppKit
import SwiftUI

/// StreamDisk's colours: amber on warm, oat-coloured surfaces.
enum Theme {
    static let accent = Color(light: 0xD47A1F, dark: 0xE8923A)
    /// Accent for text and small icons, darker in light mode so it reads on a pale surface.
    static let accentInk = Color(light: 0xB4610C, dark: 0xF0A75C)
    static let accentWash = Color(light: 0xD47A1F, 0.12, dark: 0xE8923A, 0.16)

    static let canvas = Color(light: 0xF4F1EC, dark: 0x1C1A17)
    static let card = Color(light: 0xFFFDFA, dark: 0x26231F)
    static let ink = Color(light: 0x2A2520, dark: 0xF3EEE7)
    static let inkSoft = Color(light: 0x2A2520, 0.6, dark: 0xF3EEE7, 0.6)
    static let inkFaint = Color(light: 0x2A2520, 0.38, dark: 0xF3EEE7, 0.36)
    static let stroke = Color(light: 0x2A2520, 0.09, dark: 0xF3EEE7, 0.08)
    static let track = Color(light: 0x2A2520, 0.08, dark: 0xF3EEE7, 0.1)
    static let danger = Color(light: 0xC2412D, dark: 0xF07A62)
}

extension Color {
    init(light: UInt32, _ lightOpacity: Double = 1, dark: UInt32, _ darkOpacity: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkOpacity) : NSColor(hex: light, alpha: lightOpacity)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// The StreamDisk mark: the app icon, a disk seen from above with the part already streamed
/// drawn as an amber arc. The icon file keeps a margin for its shadow, so it is drawn larger
/// than `size` to make the tile itself `size` points wide.
struct Mark: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The menu bar glyph, drawn as a template image so it follows the menu bar's appearance.
enum MenuBarGlyph {
    static func image(mounted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.4
            NSColor.black.withAlphaComponent(mounted ? 0.4 : 1).setStroke()
            ring.stroke()
            if mounted {
                // The streamed part, clockwise from the top, as on the app icon.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 - 2.5,
                              startAngle: 90, endAngle: 90 - 0.36 * 360, clockwise: true)
                arc.lineWidth = 2.4
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.6, y: rect.midY - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "StreamDisk"
        return image
    }
}

/// A thin rounded progress bar.
struct Meter: View {
    var value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent)
                    .frame(width: max(height, g.size.width * min(max(value, 0), 1)))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: value)
        .accessibilityElement()
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }
}

/// The filled amber button used for the one main action on a surface.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// A quiet pill button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.track))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    /// The raised card surface.
    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

enum Format {
    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    static func rate(_ n: UInt64) -> String {
        bytes(n) + "/s"
    }
}
