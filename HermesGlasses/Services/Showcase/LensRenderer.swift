//
// LensRenderer.swift
//
// Turns a SwiftUI lens view (DeckArt, ConfirmArt) into an image at the
// Ray-Ban Display's real 600 x 600 pixels: ImageRenderer at scale 1 with the
// exact proposed size, so one point of the art is one pixel on the lens.
// The CGImage path is platform-neutral (tests/showcase-art renders on
// macOS); the UIImage wrapper is iOS only.
//

import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

enum LensRenderer {
    static let size = CGSize(width: 600, height: 600)

    @MainActor
    static func cgImage<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.isOpaque = true
        return renderer.cgImage
    }

    #if canImport(UIKit)
    @MainActor
    static func uiImage<V: View>(_ view: V) -> UIImage? {
        cgImage(view).map { UIImage(cgImage: $0, scale: 1, orientation: .up) }
    }
    #endif
}
