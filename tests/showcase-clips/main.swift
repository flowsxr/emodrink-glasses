//
// Standalone tests for the showcase clips (MorningClipArt, ScanClipArt,
// NavigateClipArt, ClipRenderer). Renders 2-second clips at the lens's real
// 600 x 600 pixels, checks duration, size and the finished state, and writes
// stills at t = 0.2, 0.5 and 0.95 of every clip to
// .superpowers/sdd/2026-10-21-showcase/clips/ for eyeballing.
// Run from the repo root on macOS 14+ (the test reads the catalogue JSON off disk):
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/EmoDrink/DrinkRecommender.swift \
//     HermesGlasses/Services/Showcase/VendingMachine.swift \
//     HermesGlasses/Services/Showcase/GuestProfile.swift \
//     HermesGlasses/Services/Showcase/ShowcaseStrings.swift \
//     HermesGlasses/Services/Showcase/ShowcaseDirector.swift \
//     HermesGlasses/Services/Showcase/LensRenderer.swift \
//     HermesGlasses/Services/Showcase/ClipRenderer.swift \
//     HermesGlasses/Views/Showcase/LensArt.swift \
//     HermesGlasses/Views/Showcase/ClipArt.swift \
//     tests/showcase-clips/main.swift -o $TMPDIR/showcase-clips && $TMPDIR/showcase-clips
//
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

/// RGB of one pixel, (x, y) measured from the top-left.
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
}

/// Within `tolerance` per channel of a "#RRGGBB" colour (H.264 shifts colours a little).
func near(_ p: (r: Int, g: Int, b: Int), _ hex: UInt32, tolerance: Int = 40) -> Bool {
    let r = Int((hex >> 16) & 0xFF), g = Int((hex >> 8) & 0xFF), b = Int(hex & 0xFF)
    return abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance
}

func isDark(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r <= 24 && p.g <= 24 && p.b <= 24 }

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let stillsDir = repo.appendingPathComponent(".superpowers/sdd/2026-10-21-showcase/clips")
try? FileManager.default.createDirectory(at: stillsDir, withIntermediateDirectories: true)
let workDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("showcase-clips-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, _ name: String) {
    let url = stillsDir.appendingPathComponent(name + ".png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// The decoded frame at progress `t` of a clip of `duration` seconds.
func frame(_ url: URL, at t: Double, duration: Double) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let time = CMTime(seconds: min(t * duration, duration - 0.02), preferredTimescale: 600)
    return try? await generator.image(at: time).image
}

/// Duration and size checks, then the stills.
func checkClip(_ url: URL, _ name: String, duration: Double) async {
    let asset = AVURLAsset(url: url)
    let seconds = (try? await asset.load(.duration).seconds) ?? 0
    expect(abs(seconds - duration) <= 0.1, "\(name) lasts \(duration) s (got \(String(format: "%.3f", seconds)))")
    let track = try? await asset.loadTracks(withMediaType: .video).first
    let size = (try? await track?.load(.naturalSize)) ?? .zero
    expect(size == CGSize(width: 600, height: 600), "\(name) video track is 600 x 600 (got \(size))")
    for t in [0.2, 0.5, 0.95] {
        if let image = await frame(url, at: t, duration: duration) {
            writePNG(image, "\(name)-t\(Int(t * 100))")
        } else {
            expect(false, "\(name) frame at t = \(t) decodes")
        }
    }
}

@MainActor
func runAll() async {
    let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)
    let duration = 2.0

    // ease: 0 before the window, 1 after, symmetric in the middle.
    expect(ease(0.1, from: 0.2, to: 0.6) == 0, "ease is 0 before its window")
    expect(ease(0.7, from: 0.2, to: 0.6) == 1, "ease is 1 after its window")
    expect(abs(ease(0.4, from: 0.2, to: 0.6) - 0.5) < 0.001, "ease is 0.5 at the window's middle")
    expect(ease(0.25, from: 0.2, to: 0.6) < 0.125, "ease starts slow (ease-in)")

    // Cache paths: Caches/showcase-clips, one SHA-256 name per key.
    let a = ClipRenderer.cacheURL(kind: "morning", key: "assumed|en")
    let b = ClipRenderer.cacheURL(kind: "morning", key: "assumed|en")
    let c = ClipRenderer.cacheURL(kind: "morning", key: "assumed|ja")
    expect(a == b, "cacheURL is stable for the same key")
    expect(a != c, "cacheURL differs for a different key")
    expect(a.deletingLastPathComponent().lastPathComponent == "showcase-clips", "cacheURL is in a showcase-clips folder")
    expect(a.path.contains("/Caches/"), "cacheURL is under Caches")
    let stem = a.deletingPathExtension().lastPathComponent
    let hex = stem.split(separator: "-").last.map(String.init) ?? ""
    expect(hex.count == 64 && hex.allSatisfy(\.isHexDigit), "cacheURL is named by a SHA-256 hex digest")
    expect(a.pathExtension == "mp4", "cacheURL is an .mp4")

    for language in [Language.en, .ja] {
        let suffix = language == .ja ? "ja" : "en"
        let strings = ShowcaseStrings(language: language)
        let run = try! ShowcaseRun(machine: .sample, profile: .preset(.assumed), catalog: catalog,
                                   language: language, date: "2026-10-21")

        // Morning.
        let morningURL = workDir.appendingPathComponent("morning-\(suffix).mp4")
        do {
            try await ClipRenderer.render(duration: duration, to: morningURL) { t in
                MorningClipArt(snapshot: run.snapshot, strings: strings, t: t)
            }
            expect(true, "morning-\(suffix) renders")
        } catch { expect(false, "morning-\(suffix) renders (\(error))") }
        await checkClip(morningURL, "morning-\(suffix)", duration: duration)

        // The ring is drawn in the sleep colour once it has filled, and not before.
        let radius = (MorningClipArt.ringDiameter - MorningClipArt.ringLineWidth) / 2
        let angle = 36.0 * .pi / 180   // clockwise from the top
        let px = Int(MorningClipArt.ringCenter.x + radius * sin(angle))
        let py = Int(MorningClipArt.ringCenter.y - radius * cos(angle))
        if let done = await frame(morningURL, at: 0.95, duration: duration) {
            let p = pixel(done, px, py)
            expect(near(p, 0x6B5CFF), "morning-\(suffix) ring at t = 0.95 is the sleep violet #6B5CFF (got \(p))")
        } else { expect(false, "morning-\(suffix) t = 0.95 decodes") }
        if let start = await frame(morningURL, at: 0.0, duration: duration) {
            let p = pixel(start, px, py)
            expect(!near(p, 0x6B5CFF), "morning-\(suffix) ring at t = 0 has not filled yet (got \(p))")
        } else { expect(false, "morning-\(suffix) t = 0 decodes") }

        // Scan.
        let scanURL = workDir.appendingPathComponent("scan-\(suffix).mp4")
        do {
            try await ClipRenderer.render(duration: duration, to: scanURL) { t in
                ScanClipArt(machineDrinks: run.machineDrinks, strings: strings, t: t)
            }
            expect(true, "scan-\(suffix) renders")
        } catch { expect(false, "scan-\(suffix) renders (\(error))") }
        await checkClip(scanURL, "scan-\(suffix)", duration: duration)
        // Every slot lit by the end: the first slot's centre is no longer dark.
        if let done = await frame(scanURL, at: 0.95, duration: duration) {
            let slot = ScanClipArt.slotFrame(0)
            expect(!isDark(pixel(done, Int(slot.midX), Int(slot.minY + 6))),
                   "scan-\(suffix) first slot is lit at t = 0.95")
        } else { expect(false, "scan-\(suffix) t = 0.95 decodes") }

        // Navigate.
        let navURL = workDir.appendingPathComponent("navigate-\(suffix).mp4")
        do {
            try await ClipRenderer.render(duration: duration, to: navURL) { t in
                NavigateClipArt(machine: .sample, strings: strings, t: t)
            }
            expect(true, "navigate-\(suffix) renders")
        } catch { expect(false, "navigate-\(suffix) renders (\(error))") }
        await checkClip(navURL, "navigate-\(suffix)", duration: duration)
    }

    // A failed render throws and leaves nothing behind.
    let blocker = workDir.appendingPathComponent("not-a-folder")
    FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
    let bad = blocker.appendingPathComponent("clip.mp4")
    var threw = false
    do {
        try await ClipRenderer.render(duration: 0.5, to: bad) { t in
            MorningClipArt(snapshot: GuestProfile.preset(.assumed).snapshot(date: "2026-10-21"),
                           strings: ShowcaseStrings(language: .en), t: t)
        }
    } catch { threw = true }
    expect(threw, "render into an unwritable place throws")
    expect(!FileManager.default.fileExists(atPath: bad.path), "a failed render leaves no file")

    try? FileManager.default.removeItem(at: workDir)
}

await runAll()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
