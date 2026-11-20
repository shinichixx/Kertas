import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum Theme {
    static let red = Color(hex: 0xE5322D)
    static let redSoft = Color(hex: 0xFCEBEB)
    static let ink = Color(hex: 0x2C2C2A)
    static let grey = Color(hex: 0x5F5E5A)
    static let line = Color(hex: 0xD3D1C7)
    static let chip = Color(hex: 0xF1EFE8)
    static let page = Color(hex: 0xF7F6F2)
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.red
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.chip.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 0.5))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
