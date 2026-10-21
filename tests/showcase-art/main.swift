//
// Standalone tests for the showcase lens art (DeckArt, ConfirmArt, LensRenderer).
// Renders every frame at the lens's real 600 x 600 pixels, checks the size and
// that the bottom button band is empty (black), and writes PNGs to
// $TMPDIR/showcase-art/ for eyeballing against deck-v3.html.
// Run from the repo root on macOS 13+ (the test reads the catalogue JSON off disk):
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
//     HermesGlasses/Views/Showcase/LensArt.swift \
//     tests/showcase-art/main.swift -o $TMPDIR/showcase-art-test && $TMPDIR/showcase-art-test
//
import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

/// RGBA of one pixel, (x, y) measured from the top-left.
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let w = image.width, h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = (y * w + x) * 4   // bitmap memory is top row first
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), Int(buf[i + 3]))
}

func isBlack(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool { p.r <= 8 && p.g <= 8 && p.b <= 8 }

let outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("showcase-art")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name + ".png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// Renders, writes the PNG and checks size and the empty button band.
@MainActor
func check<V: View>(_ view: V, _ name: String, frontAt probe: (Int, Int)? = (300, 300)) {
    guard let image = LensRenderer.cgImage(view) else { expect(false, "\(name) renders"); return }
    writePNG(image, name)
    expect(image.width == 600 && image.height == 600, "\(name) is 600 x 600 (got \(image.width) x \(image.height))")
    guard image.width == 600, image.height == 600 else { return }
    expect(isBlack(pixel(image, 300, 590)), "\(name) pixel (300, 590) is black: the button band is empty")
    expect(isBlack(pixel(image, 300, 500)), "\(name) pixel (300, 500) is black: the bottom 110 px stay clear")
    expect(isBlack(pixel(image, 4, 4)), "\(name) corner is black: the background is see-through")
    if let (x, y) = probe {
        expect(!isBlack(pixel(image, x, y)), "\(name) pixel (\(x), \(y)) is drawn: the card is there")
    }
}

@MainActor
func runAll() {
expect(LensRenderer.size == CGSize(width: 600, height: 600), "LensRenderer.size is 600 x 600")

let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)
for language in [Language.en, .ja] {
    let run = try! ShowcaseRun(machine: .sample, profile: .preset(.assumed), catalog: catalog,
                               language: language, date: "2026-10-21")
    let deck = run.deck
    let suffix = language == .ja ? "ja" : "en"
    expect(deck.cards.count == 3, "\(suffix) sample deck has three cards")
    check(DeckArt(deck: deck, mode: .reveal), "deck-reveal-\(suffix)")
    check(DeckArt(deck: deck, mode: .why), "deck-why-\(suffix)")
    check(DeckArt(deck: deck, mode: .chosen), "deck-chosen-\(suffix)")
    let strings = ShowcaseStrings(language: language)
    check(ConfirmArt(card: deck.cards[0], line: strings.confirmLine), "confirm-\(suffix)", frontAt: nil)

    // The deck rotated, so a different drink (and colour) is in front.
    var rotated = deck
    rotated.next()
    check(DeckArt(deck: rotated, mode: .why), "deck-why-next-\(suffix)")
}

// The longest names shrink, then wrap to two lines; never truncate.
let longCard = ShowcaseCard(drinkID: "long", name: "Wonda Morning Shot Extra Large", emoji: "☕",
                            colorHex: "#FFB36B", tag: "ENERGISE · 80 MG",
                            reasons: [ShowcaseReason(label: "Short sleep", colorHex: "#6B5CFF"),
                                      ShowcaseReason(label: "HRV low", colorHex: "#FF4F7A")])
let longDeck = ShowcaseDeck(cards: [longCard], pool: [longCard])
check(DeckArt(deck: longDeck, mode: .reveal), "deck-reveal-long-single")
check(DeckArt(deck: longDeck, mode: .why), "deck-why-long-single")
check(ConfirmArt(card: longCard, line: "Nice choice. Enjoy it."), "confirm-long", frontAt: nil)
}

// Top-level code is not main-actor isolated in a plain swiftc build; it does run on the main thread.
MainActor.assumeIsolated { runAll() }

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
