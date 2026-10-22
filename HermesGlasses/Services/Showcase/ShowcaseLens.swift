//
// ShowcaseLens.swift
//
// What the showcase sends to the glasses: a rendered 600 x 600 card
// (DeckArt / ConfirmArt through LensRenderer) as a full-size Image, with at
// most three native buttons under it. The art leaves its bottom band empty
// for those buttons. Clips go out separately, as a VideoPlayer, through
// HermesDisplayManager.playShowcaseClip.
//
// No SwiftUI import: the Display DSL's Image, Text and Button would clash.
//

import MWDATDisplay
import UIKit

enum ShowcaseLens {
    static let maxButtons = 3

    /// The card image filling the lens, and a ButtonGroup of at most three
    /// buttons. Labels come from the run's `strings`; a tap calls `onTap`.
    static func card(_ image: UIImage, buttons: [ShowcaseButton], strings: ShowcaseStrings,
                     onTap: @escaping @Sendable (ShowcaseButton) -> Void) -> FlexBox {
        let shown = Array(buttons.prefix(maxButtons))
        let labelled = shown.map { (button: $0, label: $0.label(in: strings, among: shown)) }
        return FlexBox(direction: .column, spacing: 0, crossAlignment: .center) {
            Image(image: image, sizePreset: .fill)
            if !labelled.isEmpty {
                ButtonGroup {
                    for item in labelled {
                        Button(label: item.label, style: item.button.isPrimary ? .primary : .secondary,
                               onClick: { onTap(item.button) })
                    }
                }
            }
        }
    }
}
