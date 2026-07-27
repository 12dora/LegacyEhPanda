//
//  ColorCodable.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/02/03.
//  Copied from https://brunowernimont.me/howtos/make-swiftui-color-codable
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#elseif os(macOS)
import AppKit
#endif

private extension Color {
    #if os(macOS)
    typealias SystemColor = NSColor
    #else
    typealias SystemColor = UIColor
    #endif

    struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    var colorComponents: RGBA? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        #if os(macOS)
        SystemColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        guard SystemColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #endif

        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// A project-owned, round-trippable representation of a `SwiftUI.Color`.
///
/// Retroactively conforming the imported `Color` to the imported `Codable` protocols is what the
/// compiler warns about — and what would collide outright if the SDK ever declares those
/// conformances — so every type of this project encodes its colors through this value instead.
/// The encoded shape (`red`/`green`/`blue`) is deliberately identical to the retroactive
/// conformance this replaced, which keeps already persisted payloads readable.
struct CodableColor: Codable, Equatable, Hashable {
    /// `Color.blue` resolved in the sRGB space. It is a constant rather than a resolution of the
    /// dynamic system color so that constructing a default value neither depends on the current
    /// trait collection nor touches UIKit on whatever thread the value is created on.
    static let blue = CodableColor(red: 0, green: 0.478_431_37, blue: 1)

    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(_ color: Color?) {
        guard let components = color?.colorComponents else { return nil }
        red = .init(components.red)
        green = .init(components.green)
        blue = .init(components.blue)
    }

    var color: Color {
        .init(red: red, green: green, blue: blue)
    }
}
