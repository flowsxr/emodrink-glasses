//
// ClipArt.swift
//
// The showcase's three animations, each a SwiftUI view of progress `t` in
// 0...1 on the 600 x 600 black lens: ClipRenderer renders one frame per `t`
// into a short MP4 that the glasses play full screen.
//
//   * Navigate: a warm arrow and the distance counting down to 0, a "Here"
//     flourish at 0.9.
//   * Morning: the sleep ring fills (0 to 0.5), HRV and resting HR count up
//     against "your usual" (0.2 to 0.7), a heartbeat line draws (0.4 to
//     0.9), the summary fades in at 0.8.
//   * Scan: a sweep runs down a stylised machine front (0 to 0.6), its
//     slots light in order in their function colour, the names tick in
//     (four, then "+N").
//
// Rules from the showcase's Global Constraints: black is see-through, so
// everything is light with glow; smallest text 24 px. Clips play full
// screen with no native buttons, so the bottom band is free here.
// SwiftUI and Foundation only, no UIKit, so tests/showcase-clips renders
// them on macOS.
//

import SwiftUI
import Foundation

// MARK: - Easing

/// Progress through the window [a, b] of `t`, on an ease-in-out (cubic)
/// curve: 0 before the window, 1 after it.
func ease(_ t: Double, from a: Double, to b: Double) -> Double {
    guard b > a else { return t >= b ? 1 : 0 }
    let x = min(max((t - a) / (b - a), 0), 1)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

/// A softer ease-in-out (sine) for steady motion such as walking, where
/// the cubic curve would hold still too long at the start.
func easeGently(_ t: Double, from a: Double, to b: Double) -> Double {
    guard b > a else { return t >= b ? 1 : 0 }
    let x = min(max((t - a) / (b - a), 0), 1)
    return 0.5 - cos(.pi * x) / 2
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }

enum ClipColors {
    static let sleep = Color(hex: "#6B5CFF")
    static let sleepLight = Color(hex: "#BDB6FF")
    static let hrv = Color(hex: "#FF4F7A")
    static let heartRate = Color(hex: "#FFB36B")
    static let amber = Color(hex: "#FFB36B")
    static let amberDeep = Color(hex: "#FF8A3D")
    static let scan = Color(hex: "#BFF6FF")
}

// MARK: - Morning

struct MorningClipArt: View {
    let snapshot: PhysiologySnapshot
    let strings: ShowcaseStrings
    let t: Double

    static let ringCenter = CGPoint(x: 160, y: 230)
    static let ringDiameter: CGFloat = 252
    static let ringLineWidth: CGFloat = 26
    /// A full ring is an eight-hour night.
    static let sleepGoalHours = 8.0

    var body: some View {
        let ring = ease(t, from: 0, to: 0.5)
        let count = ease(t, from: 0.2, to: 0.7)
        let line = ease(t, from: 0.4, to: 0.9)
        let summary = ease(t, from: 0.8, to: 0.92)
        let fill = min(snapshot.sleep.hours / Self.sleepGoalHours, 1)

        ClipCanvas {
            ClipHeading(text: strings.morningHeading, appear: ease(t, from: 0, to: 0.1))

            // Sleep ring.
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: Self.ringLineWidth)
                if ring > 0.001 {
                    Circle()
                        .trim(from: 0, to: fill * ring)
                        .stroke(ClipColors.sleep, style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: ClipColors.sleep.opacity(0.85), radius: 16)
                }
                VStack(spacing: 2) {
                    SplitFigure(text: strings.sleepDuration(hours: snapshot.sleep.hours * ring),
                                digitSize: 62, unitSize: 30)
                        .foregroundStyle(Color.white)
                    Text(strings.sleepWord)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(ClipColors.sleepLight)
                }
                .frame(width: Self.ringDiameter - Self.ringLineWidth * 2 - 8)
            }
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)
            .scaleEffect(0.92 + 0.08 * ease(t, from: 0, to: 0.3))
            .position(Self.ringCenter)

            // HRV and resting heart rate against the guest's usual.
            VStack(alignment: .leading, spacing: 26) {
                stat(label: strings.hrvLabel, color: ClipColors.hrv,
                     value: snapshot.hrvMs, delta: snapshot.hrvDelta, unit: strings.hrvUnit,
                     progress: count, appear: ease(t, from: 0.15, to: 0.3),
                     deltaAppear: ease(t, from: 0.5, to: 0.65))
                stat(label: strings.restingHRLabel, color: ClipColors.heartRate,
                     value: snapshot.restingHR, delta: snapshot.restingHRDelta, unit: strings.bpmUnit,
                     progress: count, appear: ease(t, from: 0.22, to: 0.37),
                     deltaAppear: ease(t, from: 0.55, to: 0.7))
            }
            .frame(width: 250, alignment: .leading)
            .position(x: 445, y: 232)

            // Heartbeat line.
            ZStack {
                HeartbeatShape()
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                HeartbeatShape()
                    .trim(from: 0, to: line)
                    .stroke(ClipColors.hrv, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .shadow(color: ClipColors.hrv.opacity(0.9), radius: 10)
            }
            .frame(width: 520, height: 84)
            .position(x: 300, y: 418)

            // Summary.
            Text(Self.balanced(strings.summary(for: snapshot.bodyState)))
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)  // 32 x 0.8 = 25.6 px
                .shadow(color: Color.white.opacity(0.35), radius: 8)
                .frame(width: 540, height: 100)
                .opacity(summary)
                .offset(y: (1 - summary) * 14)
                .position(x: 300, y: 522)
        }
    }

    private func stat(label: String, color: Color, value: Double?, delta: Double?, unit: String,
                      progress: Double, appear: Double, deltaAppear: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value.map { "\(Int(($0 * progress).rounded()))" } ?? "–")
                    .font(.system(size: 66, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .shadow(color: color.opacity(0.6), radius: 10)
                Text(unit)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            if let delta {
                Text(strings.versusUsual(Int((delta * progress).rounded())))
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(24.0 / 26)
                    .opacity(deltaAppear)
            }
        }
        .opacity(appear)
        .offset(x: (1 - appear) * 24)
    }
}

extension MorningClipArt {
    /// A Japanese summary breaks after its first 。 rather than mid-word.
    static func balanced(_ text: String) -> String {
        guard let stop = text.firstIndex(of: "。"), text.index(after: stop) < text.endIndex else { return text }
        return String(text[...stop]) + "\n" + String(text[text.index(after: stop)...])
    }
}

/// An ECG-like trace, three beats across the rect.
private struct HeartbeatShape: Shape {
    func path(in rect: CGRect) -> Path {
        // (x, y) in a 0...1 beat, y from the top; 0.62 is the baseline.
        let beat: [(Double, Double)] = [
            (0.00, 0.62), (0.16, 0.62), (0.22, 0.52), (0.28, 0.62), (0.36, 0.62),
            (0.40, 0.72), (0.45, 0.02), (0.50, 0.98), (0.55, 0.62), (0.66, 0.62),
            (0.74, 0.44), (0.82, 0.62), (1.00, 0.62)
        ]
        let beats = 3
        let width = rect.width / CGFloat(beats)
        var path = Path()
        for b in 0..<beats {
            for (i, point) in beat.enumerated() where !(b > 0 && i == 0) {
                let p = CGPoint(x: rect.minX + width * (CGFloat(b) + CGFloat(point.0)),
                                y: rect.minY + rect.height * CGFloat(point.1))
                if b == 0 && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        return path
    }
}

// MARK: - Scan

struct ScanClipArt: View {
    let machineDrinks: [Drink]
    let strings: ShowcaseStrings
    let t: Double

    static let slotCount = 8
    static let machineFrame = CGRect(x: 40, y: 84, width: 250, height: 486)
    private static let columns = 2
    private static let slotArea = CGRect(x: 60, y: 152, width: 210, height: 334)
    private static let slotGap: CGFloat = 14
    private static let sweepTop: CGFloat = 140
    private static let sweepBottom: CGFloat = 500
    private static let visibleNames = 4

    /// Slot `i`, row-major, two to a row.
    static func slotFrame(_ i: Int) -> CGRect {
        let rows = slotCount / columns
        let w = (slotArea.width - slotGap * CGFloat(columns - 1)) / CGFloat(columns)
        let h = (slotArea.height - slotGap * CGFloat(rows - 1)) / CGFloat(rows)
        let col = i % columns, row = i / columns
        return CGRect(x: slotArea.minX + CGFloat(col) * (w + slotGap),
                      y: slotArea.minY + CGFloat(row) * (h + slotGap), width: w, height: h)
    }

    private var sweepY: CGFloat { lerp(Self.sweepTop, Self.sweepBottom, ease(t, from: 0, to: 0.6)) }

    /// 0 until the sweep reaches the slot's middle, 1 shortly after; the
    /// right-hand slot a beat after the left, so they light in order.
    private func lit(_ i: Int) -> Double {
        let slot = Self.slotFrame(i)
        let threshold = slot.midY + CGFloat(i % Self.columns) * 22
        return ease(Double(sweepY - threshold), from: 0, to: 34)
    }

    /// How many drinks have been read so far: the lit slots, then the rest
    /// of the machine once the sweep is done.
    private var revealed: Int {
        let inSlots = (0..<min(machineDrinks.count, Self.slotCount)).filter { lit($0) > 0.5 }.count
        let rest = max(0, machineDrinks.count - Self.slotCount)
        return inSlots + (t >= 0.6 ? rest : 0)
    }

    var body: some View {
        let sweepAlpha = 1 - ease(t, from: 0.6, to: 0.68)
        let found = ease(t, from: 0.66, to: 0.8)

        ClipCanvas {
            ClipHeading(text: strings.scanHeading, appear: ease(t, from: 0, to: 0.1))

            // The machine front.
            let body = RoundedRectangle(cornerRadius: 26, style: .continuous)
            body
                .strokeBorder(Color.white.opacity(0.6), lineWidth: 3)
                .shadow(color: Color.white.opacity(0.3), radius: 12)
                .frame(width: Self.machineFrame.width, height: Self.machineFrame.height)
                .position(x: Self.machineFrame.midX, y: Self.machineFrame.midY)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .frame(width: 210, height: 34)
                .position(x: Self.machineFrame.midX, y: 118)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 3)
                .frame(width: 150, height: 44)
                .position(x: Self.machineFrame.midX, y: 528)

            ForEach(0..<Self.slotCount, id: \.self) { i in
                slot(i)
            }

            // The sweep, with a soft trail above it.
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [ClipColors.scan.opacity(0), ClipColors.scan.opacity(0.22)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
                Capsule()
                    .fill(ClipColors.scan)
                    .frame(height: 4)
                    .shadow(color: ClipColors.scan, radius: 10)
            }
            .frame(width: Self.machineFrame.width - 20, height: 70)
            .position(x: Self.machineFrame.midX, y: sweepY - 33)
            .opacity(sweepAlpha)

            // Names, four at most, then "+N".
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(machineDrinks.prefix(Self.visibleNames).enumerated()), id: \.offset) { i, drink in
                    nameRow(drink, appear: ease(lit(i), from: 0.3, to: 1))
                }
                let more = revealed - Self.visibleNames
                if more > 0 {
                    Text("+\(more)")
                        .font(.system(size: 32, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .frame(width: 254, height: 380, alignment: .topLeading)
            .position(x: 449, y: 290)

            Text(strings.scanLine(count: machineDrinks.count))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.white)
                .shadow(color: Color.white.opacity(0.4), radius: 8)
                .lineLimit(2)
                .minimumScaleFactor(24.0 / 28)
                .frame(width: 254, height: 80, alignment: .bottomLeading)
                .opacity(found)
                .offset(y: (1 - found) * 12)
                .position(x: 449, y: 528)
        }
    }

    @ViewBuilder
    private func slot(_ i: Int) -> some View {
        let frame = Self.slotFrame(i)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if i < machineDrinks.count {
            let drink = machineDrinks[i]
            let color = Self.color(for: drink)
            let on = lit(i)
            ZStack {
                shape.strokeBorder(Color.white.opacity(0.22 * (1 - on)),
                                   style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                shape.fill(color.opacity(0.3 * on))
                shape.strokeBorder(color.opacity(on), lineWidth: 3)
                    .shadow(color: color.opacity(0.9 * on), radius: 12 * on)
                Text(drink.displayEmoji)
                    .font(.system(size: 40))
                    .opacity(on)
                    .scaleEffect(0.6 + 0.4 * on)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
        } else {
            shape.strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    private func nameRow(_ drink: Drink, appear: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(Self.color(for: drink))
                .frame(width: 16, height: 16)
                .shadow(color: Self.color(for: drink), radius: 6)
            ScanName(text: strings.language == .ja ? drink.nameJa : drink.name)
                .foregroundStyle(Color.white)
        }
        .opacity(appear)
        .offset(x: (1 - appear) * 22)
    }

    /// The drink's function colour; custom drinks keep the deck's neutral.
    static func color(for drink: Drink) -> Color {
        Color(hex: drink.kind == "custom" ? ShowcaseRun.customColorHex : drink.displayColorHex)
    }
}

// MARK: - Navigate

struct NavigateClipArt: View {
    let machine: VendingMachine
    let strings: ShowcaseStrings
    let t: Double

    private static let arrowCenter = CGPoint(x: 300, y: 232)
    private static let trackY: CGFloat = 548

    var body: some View {
        let walk = easeGently(t, from: 0.04, to: 0.86)
        let meters = Int((Double(machine.distanceMeters) * (1 - walk)).rounded())
        let enter = ease(t, from: 0, to: 0.12)
        let leave = ease(t, from: 0.86, to: 0.93)
        let here = ease(t, from: 0.9, to: 0.97)
        let burst = ease(t, from: 0.9, to: 1.0)
        // A gentle forward bob while walking, still at the end.
        let bob = sin(t * .pi * 2 * 4) * 8 * (1 - leave)

        ClipCanvas {
            ClipHeading(text: strings.navigateHeading, appear: enter)

            // Halo and arrow.
            Circle()
                .fill(RadialGradient(colors: [ClipColors.amber.opacity(0.22), .clear],
                                     center: .center, startRadius: 10, endRadius: 170))
                .frame(width: 340, height: 340)
                .scaleEffect(1 + 0.06 * sin(t * .pi * 2 * 4))
                .opacity(enter * (1 - leave))
                .position(Self.arrowCenter)
            ArrowShape()
                .fill(LinearGradient(colors: [ClipColors.amber, ClipColors.amberDeep.opacity(0.25)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: ClipColors.amber.opacity(0.8), radius: 18)
                .frame(width: 190, height: 230)
                .scaleEffect((0.85 + 0.15 * enter) * (1 + 0.15 * leave))
                .offset(y: -bob - 40 * leave)
                .opacity(enter * (1 - leave))
                .position(Self.arrowCenter)

            // "Here": a ring that settles, and one that bursts outward.
            Circle()
                .stroke(ClipColors.amber.opacity(1 - burst), lineWidth: 6)
                .frame(width: 210, height: 210)
                .scaleEffect(0.8 + 0.8 * burst)
                .opacity(here > 0 ? 1 : 0)
                .position(Self.arrowCenter)
            ZStack {
                Circle()
                    .fill(ClipColors.amber.opacity(0.18))
                Circle()
                    .strokeBorder(ClipColors.amber, lineWidth: 8)
                    .shadow(color: ClipColors.amber, radius: 18)
                Text(strings.here)
                    .font(.system(size: 64, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .shadow(color: ClipColors.amber, radius: 12)
            }
            .frame(width: 220, height: 220)
            .scaleEffect(0.6 + 0.4 * here)
            .opacity(here)
            .position(Self.arrowCenter)

            // Distance, counting down.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(meters)")
                    .font(.system(size: 112, weight: .heavy))
                    .monospacedDigit()
                Text(strings.distanceUnit)
                    .font(.system(size: 40, weight: .bold))
            }
            .foregroundStyle(Color.white)
            .shadow(color: ClipColors.amber.opacity(0.55), radius: 12)
            .opacity(enter * (1 - leave))
            .position(x: 300, y: 418)

            Text(machine.name)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(24.0 / 32)
                .frame(width: 520)
                .opacity(enter)
                .position(x: 300, y: 492 - 70 * here)

            // The route: a track that fills toward the machine.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16)).frame(height: 6)
                Capsule().fill(ClipColors.amber).frame(width: max(6, 400 * walk), height: 6)
                    .shadow(color: ClipColors.amber, radius: 8)
                Circle().fill(Color.white).frame(width: 18, height: 18)
                    .shadow(color: ClipColors.amber, radius: 10)
                    .offset(x: 400 * walk - 9)
            }
            .frame(width: 400, height: 20)
            .opacity(enter)
            .position(x: 300, y: Self.trackY)
        }
    }
}

/// The storyboard's arrow: a head over a shaft, pointing up (ahead).
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: p(0.5, 0))
        path.addLine(to: p(1, 0.46))
        path.addLine(to: p(0.68, 0.46))
        path.addLine(to: p(0.68, 1))
        path.addLine(to: p(0.32, 1))
        path.addLine(to: p(0.32, 0.46))
        path.addLine(to: p(0, 0.46))
        path.closeSubpath()
        return path
    }
}

// MARK: - Shared pieces

/// The 600 x 600 black lens, children placed by absolute position.
private struct ClipCanvas<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            content
        }
        .frame(width: LensArtMetrics.side, height: LensArtMetrics.side, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

/// The step's heading, small caps across the top.
private struct ClipHeading: View {
    let text: String
    let appear: Double

    var body: some View {
        let ascii = text.unicodeScalars.allSatisfy(\.isASCII)
        Text(ascii ? text.uppercased() : text)
            .font(.system(size: 26, weight: .heavy, design: ascii ? .monospaced : .default))
            .tracking(ascii ? 3 : 1)
            .foregroundStyle(Color.white.opacity(0.78))
            .lineLimit(1)
            .frame(width: 560)
            .opacity(appear)
            .position(x: 300, y: 44)
    }
}

/// A drink name at 28 px, then 24 px, then wrapped at a space (most
/// balanced first), so a Japanese name never breaks mid-word.
private struct ScanName: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(text, 28)
            line(text, 26)
            line(text, 24)
            ForEach(Array(wraps.enumerated()), id: \.offset) { _, wrap in line(wrap.text, wrap.size) }
            Text(text)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wraps: [(text: String, size: CGFloat)] {
        let splits = lensTwoLineSplits(text)
        return splits.map { ($0, 28) } + splits.map { ($0, 24) }
    }

    private func line(_ string: String, _ size: CGFloat) -> some View {
        Text(string)
            .font(.system(size: size, weight: .semibold))
            .fixedSize()
    }
}

/// "5h48" with the digits large and the units small, on one baseline.
private struct SplitFigure: View {
    let text: String
    let digitSize: CGFloat
    let unitSize: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            ForEach(Array(Self.runs(text).enumerated()), id: \.offset) { _, run in
                Text(run.text)
                    .font(.system(size: run.digits ? digitSize : unitSize, weight: run.digits ? .heavy : .bold))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        // The units are the smallest text: never below 24 px.
        .minimumScaleFactor(24 / unitSize)
    }

    static func runs(_ text: String) -> [(text: String, digits: Bool)] {
        var out: [(text: String, digits: Bool)] = []
        for ch in text {
            let digit = ch.isNumber
            if let last = out.last, last.digits == digit {
                out[out.count - 1].text.append(ch)
            } else {
                out.append((String(ch), digit))
            }
        }
        return out
    }
}
