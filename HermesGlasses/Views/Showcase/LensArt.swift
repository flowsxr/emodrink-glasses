//
// LensArt.swift
//
// The showcase's lens art, drawn at the Ray-Ban Display's real 600 x 600
// pixels (one point = one pixel; LensRenderer renders at scale 1) and sent
// to the lens as an image. Layout follows the agreed deck-v3 mockup: the
// front card in full colour with a glow, up to two cards fanned behind it
// with their emoji and name on the exposed edge.
//
// Rules from the showcase's Global Constraints:
//   * Black is see-through on the display, so the canvas is pure black and
//     everything drawn is light, full colour, with glow.
//   * Smallest text 24 px; drink names about 52 px, shrinking to 40 px and
//     then wrapping to two lines, never truncating (only the back cards'
//     edge labels may truncate).
//   * A card shows only an emoji, the name, one tag and at most two
//     two-word reasons. No sentences.
//   * The bottom 110 px stay empty: the lens buttons are native (Task 6).
//
// SwiftUI and Foundation only, no UIKit, so tests/showcase-art renders it
// on macOS.
//

import SwiftUI
import Foundation

// MARK: - Metrics

enum LensArtMetrics {
    static let side: CGFloat = 600
    /// The native buttons' band at the bottom: nothing is drawn below this.
    static let buttonBand: CGFloat = 110
    static var drawableBottom: CGFloat { side - buttonBand }
    static let cornerRadius: CGFloat = 28
    static let padding: CGFloat = 28
    static let nameSize: CGFloat = 52
    static let nameMinSize: CGFloat = 40
    static let edgeSize: CGFloat = 28
    static let reasonSize: CGFloat = 34
    static let tagSize: CGFloat = 24
    static let emojiSize: CGFloat = 110
}

// MARK: - Deck

struct DeckArt: View {
    let deck: ShowcaseDeck
    let mode: DeckMode

    var body: some View {
        LensCanvas {
            switch mode {
            case .chosen:
                if let front = deck.cards.first {
                    FrontCard(card: front, style: .reveal, glowRadius: 34)
                        .lensPlaced(Self.chosenFrame)
                }
            case .reveal, .why:
                let layout = mode == .why ? Self.whyLayout : Self.revealLayout
                // Farthest first, so the nearer card overlaps it.
                if deck.cards.count > 2 {
                    BackCard(card: deck.cards[2], alignment: .leading, opacity: 0.55, labelWidth: 230)
                        .lensPlaced(layout.far, rotation: 5)
                }
                if deck.cards.count > 1 {
                    BackCard(card: deck.cards[1], alignment: .trailing, opacity: 0.7, labelWidth: 388)
                        .lensPlaced(layout.near, rotation: -4)
                }
                if let front = deck.cards.first {
                    FrontCard(card: front, style: mode == .why ? .why : .reveal, glowRadius: 22)
                        .lensPlaced(layout.front)
                }
            }
        }
    }

    private struct Layout { let far: CGRect; let near: CGRect; let front: CGRect }

    // deck-v3 frames 4 and 5, mirrored left to right. With the far card at
    // +5 degrees and the near one at -4, the mockup's arrangement leaves the
    // far card's label under the near card (the mockup only showed it through
    // translucency). Mirrored, each card's raised corner carries its label:
    // the far card's top-left, the near card's top-right. The front card's
    // bottom sits at 466, so its glow fades out before the button band at 490.
    private static let revealLayout = Layout(
        far: CGRect(x: 30, y: 22, width: 420, height: 150),
        near: CGRect(x: 130, y: 74, width: 440, height: 150),
        front: CGRect(x: 30, y: 142, width: 540, height: 324))

    private static let whyLayout = Layout(
        far: CGRect(x: 30, y: 16, width: 420, height: 130),
        near: CGRect(x: 130, y: 64, width: 440, height: 130),
        front: CGRect(x: 30, y: 126, width: 540, height: 340))

    private static let chosenFrame = CGRect(x: 70, y: 60, width: 460, height: 380)
}

// MARK: - Confirm

struct ConfirmArt: View {
    let card: ShowcaseCard
    let line: String

    var body: some View {
        let palette = CardPalette(hex: card.colorHex)
        LensCanvas {
            VStack(spacing: 26) {
                ZStack {
                    Circle()
                        .fill(palette.base.opacity(0.22))
                    Circle()
                        .strokeBorder(palette.base, lineWidth: 7)
                    Image(systemName: "checkmark")
                        .font(.system(size: 76, weight: .heavy))
                        .foregroundStyle(palette.light)
                }
                .frame(width: 156, height: 156)
                .shadow(color: palette.base.opacity(0.75), radius: 26)

                FittedName(text: "\(card.emoji) \(card.name)", alignment: .center)
                    .foregroundStyle(Color.white)

                Text(line)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(palette.light)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            .lensPlaced(CGRect(x: 0, y: 10, width: LensArtMetrics.side,
                               height: LensArtMetrics.drawableBottom - 20))
        }
    }
}

// MARK: - Cards

private struct FrontCard: View {
    enum Style { case reveal, why }

    let card: ShowcaseCard
    let style: Style
    let glowRadius: CGFloat

    var body: some View {
        let palette = CardPalette(hex: card.colorHex)
        ZStack {
            RoundedRectangle(cornerRadius: LensArtMetrics.cornerRadius, style: .continuous)
                .fill(palette.gradient)
                .shadow(color: palette.base.opacity(0.6), radius: glowRadius)
            content
                .foregroundStyle(palette.ink)
                .padding(LensArtMetrics.padding)
        }
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .reveal:
            // A name that wraps to two lines takes a smaller emoji, so the
            // card never outgrows its frame.
            ViewThatFits(in: .vertical) {
                revealStack(emoji: LensArtMetrics.emojiSize)
                revealStack(emoji: 84)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .why:
            VStack(alignment: .leading, spacing: 14) {
                FittedName(text: "\(card.emoji) \(card.name)", alignment: .leading)
                ForEach(Array(card.reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                    HStack(spacing: 14) {
                        Circle()
                            .fill(Color(hex: reason.colorHex))
                            .frame(width: 22, height: 22)
                        Text(reason.label)
                            .font(.system(size: LensArtMetrics.reasonSize, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                Spacer(minLength: 0)
                TagText(text: card.tag)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func revealStack(emoji size: CGFloat) -> some View {
        VStack(spacing: 14) {
            Text(card.emoji)
                .font(.system(size: size))
            FittedName(text: card.name, alignment: .center)
            TagText(text: card.tag)
        }
    }
}

/// A card fanned behind the front one. Only its top edge shows, carrying the
/// emoji and name; the label may truncate, but never wraps.
private struct BackCard: View {
    let card: ShowcaseCard
    let alignment: HorizontalAlignment
    let opacity: Double
    /// The exposed width: a longer label ends in an ellipsis there rather
    /// than disappearing under the card in front.
    let labelWidth: CGFloat

    var body: some View {
        let palette = CardPalette(hex: card.colorHex)
        let shape = RoundedRectangle(cornerRadius: LensArtMetrics.cornerRadius, style: .continuous)
        ZStack(alignment: .top) {
            // An opaque black backing: dimming over black reads as a fainter
            // card on the lens, and the card behind never bleeds through.
            shape.fill(Color.black)
            ZStack(alignment: .top) {
                shape.fill(palette.gradient)
                Text("\(card.emoji) \(card.name)")
                    .font(.system(size: LensArtMetrics.edgeSize, weight: .heavy))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: labelWidth,
                           alignment: alignment == .trailing ? .trailing : .leading)
                    .frame(maxWidth: .infinity,
                           alignment: alignment == .trailing ? .trailing : .leading)
                    .padding(.horizontal, 26)
                    .padding(.top, 20)
            }
            .opacity(opacity)
        }
    }
}

/// A drink name at 52 px, stepping down to 40 px on one line, then wrapping
/// to two lines at 40 px. It never truncates. A wrap breaks at a space when
/// one fits, most balanced first, so a Japanese name never splits mid-word
/// (SwiftUI would otherwise break katakana between any two characters).
private struct FittedName: View {
    let text: String
    let alignment: TextAlignment

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(text, 52)
            line(text, 48)
            line(text, 44)
            line(text, 40)
            ForEach(Self.twoLineSplits(text), id: \.self) { split in
                line(split, LensArtMetrics.nameMinSize)
            }
            Text(text)
                .font(.system(size: LensArtMetrics.nameMinSize, weight: .heavy))
                .multilineTextAlignment(alignment)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ string: String, _ size: CGFloat) -> some View {
        Text(string)
            .font(.system(size: size, weight: .heavy))
            .multilineTextAlignment(alignment)
            .lineSpacing(-4)
            .fixedSize()
    }

    /// Every "first\nsecond" split at a space, the most balanced first. A
    /// space right after a leading emoji is not a break.
    static func twoLineSplits(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return [] }
        var splits: [(String, Int)] = []
        for i in 1..<words.count {
            let first = words[..<i].joined(separator: " ")
            let second = words[i...].joined(separator: " ")
            if i == 1, !first.contains(where: \.isLetter) { continue }
            splits.append((first + "\n" + second, abs(first.count - second.count)))
        }
        return splits.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// The function tag: monospaced caps in English as in deck-v3; Japanese
/// keeps the system face, where the monospaced fallback spaces kana oddly.
private struct TagText: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            let ascii = text.unicodeScalars.allSatisfy { $0.isASCII || $0 == "\u{00B7}" }
            Text(text)
                .font(.system(size: LensArtMetrics.tagSize, weight: .heavy,
                              design: ascii ? .monospaced : .default))
                .tracking(ascii ? 2 : 1)
                .lineLimit(1)
        }
    }
}

// MARK: - Canvas and placement

/// The 600 x 600 black lens, with everything below the drawable area masked
/// off (a short fade, so a glow never ends on a hard line).
private struct LensCanvas<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            ZStack(alignment: .topLeading) { content }
                .frame(width: LensArtMetrics.side, height: LensArtMetrics.side, alignment: .topLeading)
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: LensArtMetrics.drawableBottom - 16)
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                        Spacer(minLength: 0)
                    }
                )
        }
        .frame(width: LensArtMetrics.side, height: LensArtMetrics.side)
        .environment(\.colorScheme, .dark)
    }
}

private extension View {
    /// Places a view in a rect of the 600 x 600 canvas, rotated about its centre.
    func lensPlaced(_ rect: CGRect, rotation degrees: Double = 0) -> some View {
        frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(degrees))
            .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Colour

/// A card's colours, all from its one hex: a light tint at the top-left, the
/// hex itself at the bottom-right, and a deep tint of the same hue for text.
private struct CardPalette {
    let base: Color
    let light: Color
    let ink: Color

    init(hex: String) {
        let rgb = RGB(hex: hex)
        base = rgb.color
        light = rgb.mixed(with: RGB(r: 1, g: 1, b: 1), amount: 0.72).color
        let hsb = rgb.hsb
        let saturation = hsb.s < 0.15 ? hsb.s : max(hsb.s, 0.8)
        ink = Color(hue: hsb.h, saturation: saturation, brightness: 0.2)
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [light, base], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct RGB {
    let r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// "#RRGGBB" or "RRGGBB"; anything unreadable is a neutral warm grey.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(r: 0.85, g: 0.83, b: 0.8)
            return
        }
        self.init(r: Double((value >> 16) & 0xFF) / 255,
                  g: Double((value >> 8) & 0xFF) / 255,
                  b: Double(value & 0xFF) / 255)
    }

    var color: Color { Color(red: r, green: g, blue: b) }

    func mixed(with other: RGB, amount t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var hsb: (h: Double, s: Double, b: Double) {
        let maxV = max(r, g, b), minV = min(r, g, b), delta = maxV - minV
        var hue = 0.0
        if delta > 0 {
            if maxV == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxV == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxV == 0 ? 0 : delta / maxV, maxV)
    }
}

fileprivate extension Color {
    /// "#RRGGBB" as a colour. Private to the lens art: HermesDesign's
    /// `Color(hex: UInt32)` sits in a UIKit file the macOS suite can't build.
    init(hex: String) { self = RGB(hex: hex).color }
}
