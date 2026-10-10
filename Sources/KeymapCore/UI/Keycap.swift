import AppKit
import SwiftUI
import ViaKit

extension KeyStyle {
    /// A light system tint that tells key kinds apart without shouting.
    var tint: Color? {
        switch self {
        case .standard, .transparent: return nil
        case .modifier: return .gray
        case .media: return .teal
        case .layer: return .purple
        case .macro: return .orange
        case .lighting: return .pink
        case .mouse: return .green
        case .dualRole: return .indigo
        case .special: return .red
        }
    }
}

extension KeyStyle {
    /// Dark mode: media, layer and lighting keys get their own solid fills ("cool and warm": sky, lavender, amber) instead
    /// of a wash of the system tint over the slate cap.
    var darkFill: Color? {
        switch self {
        case .media: return Color(red: 0.298, green: 0.561, blue: 0.690)      // #4C8FB0
        case .layer: return Color(red: 0.494, green: 0.420, blue: 0.769)      // #7E6BC4
        case .lighting: return Color(red: 0.788, green: 0.533, blue: 0.275)   // #C98846
        default: return nil
        }
    }
}

/// One keycap, drawn with system colours so it follows Light and Dark mode.
struct Keycap: View {
    @Environment(\.colorScheme) private var scheme
    let label: KeyLabel
    var width: CGFloat
    var height: CGFloat
    var selected = false
    var changed = false
    var pressed = false
    /// Fills the cap with a colour (per-key RGB or a Mix RGB zone).
    var fill: Color?
    var badge: String?
    /// Overrides the legend colour (used when the cap is filled with a strong colour).
    var legend: Color?

    var body: some View {
        let radius = min(width, height) * 0.22
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color.capBase(scheme))
            if scheme == .dark, let solid = label.style.darkFill { shape.fill(solid) }
            else if let tint = label.style.tint { shape.fill(tint.opacity(scheme == .dark ? 0.40 : 0.20)) }
            if let fill { shape.fill(fill) }
            if pressed { shape.fill(Theme.pressed.opacity(0.65)) }
            shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.16) : Color(nsColor: .separatorColor), lineWidth: 1)
            Text(label.short)
                .font(.system(size: legendSize, weight: .medium))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(legend.map { AnyShapeStyle($0) } ?? styleLegend)
                .padding(.horizontal, width * 0.08)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
        .overlay { if selected { shape.stroke(Color.accentColor, lineWidth: 3) } }
        .overlay(alignment: .topTrailing) {
            if changed {
                Circle().fill(Theme.changed).frame(width: max(7, width * 0.17), height: max(7, width * 0.17))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)).offset(x: 3, y: -3)
            }
        }
        .overlay(alignment: label.side == "L" ? .bottomLeading : .bottomTrailing) {
            if let side = label.side, badge == nil {
                Text(side).font(.system(size: max(7, min(width, height) * 0.2), weight: .bold, design: .rounded))
                    .foregroundStyle(legend.map { AnyShapeStyle($0.opacity(0.75)) } ?? AnyShapeStyle(.secondary))
                    .padding(.horizontal, min(width, height) * 0.1).padding(.vertical, min(width, height) * 0.04)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Text(badge).font(.system(size: max(8, min(width, height) * 0.24), weight: .bold)).foregroundStyle(.primary)
                    .padding(.horizontal, 3).background(Capsule().fill(Color.capBase(scheme))).padding(2)
            }
        }
    }

    /// Legend colour: on the solid dark-mode fills it follows the fill's lightness; otherwise the usual primary text.
    private var styleLegend: AnyShapeStyle {
        if label.style == .transparent { return AnyShapeStyle(.tertiary) }
        if scheme == .dark, let solid = label.style.darkFill, fill == nil { return AnyShapeStyle(solid.isDark ? Color.white : Color(red: 0.06, green: 0.08, blue: 0.13)) }
        return AnyShapeStyle(.primary)
    }

    private var legendSize: CGFloat {
        let base = min(width, height)
        return label.short.count <= 1 ? base * 0.44 : base * 0.28
    }
}

/// Press feedback for tappable keycaps.
struct KeycapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Where the knob's press switch sits in the matrix.
enum KnobLayout {
    static let press = MatrixPosition(row: 0, col: 13)
}

/// What turning the knob does on the layer being shown.
struct KnobTurns {
    let left: KeyLabel
    let right: KeyLabel
}

/// The rotary knob: a round cap the same size and finish as a keycap. A notch on top shows it turns, the chevrons
/// are turn left and turn right, and the round button in the middle is the click. What each one does is in the
/// tooltip and the Knob panel.
struct KnobView: View {
    @Environment(\.colorScheme) private var scheme
    var diameter: CGFloat
    var highlighted = false      // the Knob panel is showing
    var selected = false         // the press key is selected for editing
    var changed = false
    var pressed = false
    var flashLeft = false        // Key Test: the knob was just turned left
    var flashRight = false       // ... or right

    var body: some View {
        let button = diameter * 0.36
        ZStack {
            Circle().fill(Color.capBase(scheme))
            Circle().fill(Color.secondary.opacity(scheme == .dark ? 0.10 : 0.16))
            Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            Capsule().fill(Color.secondary).frame(width: max(2, diameter * 0.07), height: diameter * 0.17).offset(y: -diameter * 0.355)
            Image(systemName: "chevron.left").font(.system(size: diameter * 0.2, weight: .bold)).foregroundStyle(flashLeft ? AnyShapeStyle(Theme.pressed) : AnyShapeStyle(.secondary)).offset(x: -diameter * 0.31)
            Image(systemName: "chevron.right").font(.system(size: diameter * 0.2, weight: .bold)).foregroundStyle(flashRight ? AnyShapeStyle(Theme.pressed) : AnyShapeStyle(.secondary)).offset(x: diameter * 0.31)
            Circle().fill(pressed ? Theme.pressed.opacity(0.75) : Color.capBase(scheme)).frame(width: button, height: button)
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 0.8, y: 0.8)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
        .overlay { if highlighted || selected { Circle().stroke(Color.accentColor, lineWidth: 3).padding(-3) } }
        .overlay(alignment: .topTrailing) {
            if changed {
                Circle().fill(Theme.changed).frame(width: max(7, diameter * 0.17), height: max(7, diameter * 0.17))
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)).offset(x: 3, y: -3)
            }
        }
    }
}

extension Color {
    /// The face of a plain keycap: the system control colour in Light, a slate blue in Dark so caps read as lifted off the glass.
    static func capBase(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.25, green: 0.28, blue: 0.37) : Color(nsColor: .controlBackgroundColor)
    }

    /// True when the colour is dark enough that a white legend reads better on it.
    var isDark: Bool {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.55
    }
}
