//
//  ClipboardClient.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/19.
//

import SwiftUI
import ComposableArchitecture
import UniformTypeIdentifiers

struct ClipboardClient {
    let url: () -> URL?
    let changeCount: () -> Int
    let saveText: (String) -> Void
    let saveImage: (UIImage, Bool) -> Void
}

extension ClipboardClient {
    static let live: Self = .init(
        url: {
            if UIPasteboard.general.hasURLs {
                return UIPasteboard.general.url
            } else {
                return URL(string: UIPasteboard.general.string ?? "")
            }
        },
        changeCount: {
            UIPasteboard.general.changeCount
        },
        saveText: { text in
            UIPasteboard.general.string = text
        },
        // Encoding is expensive enough to keep off the main thread, but UIPasteboard is
        // UIKit state and must only be mutated on the main actor; the animated branch
        // previously did both on a global utility queue.
        saveImage: { (image, isAnimated) in
            Task {
                let data: Data? = isAnimated
                    ? await Task.detached(priority: .utility) { image.kf.data(format: .GIF) }.value
                    : nil
                await MainActor.run {
                    if isAnimated {
                        guard let data else { return }
                        UIPasteboard.general.setData(data, forPasteboardType: UTType.gif.identifier)
                    } else {
                        UIPasteboard.general.image = image
                    }
                }
            }
        }
    )
}

// MARK: API
enum ClipboardClientKey: DependencyKey {
    static let liveValue = ClipboardClient.live
    static let previewValue = ClipboardClient.noop
    static let testValue = ClipboardClient.unimplemented
}

extension DependencyValues {
    var clipboardClient: ClipboardClient {
        get { self[ClipboardClientKey.self] }
        set { self[ClipboardClientKey.self] = newValue }
    }
}

// MARK: Test
extension ClipboardClient {
    static let noop: Self = .init(
        url: { nil },
        changeCount: { 0 },
        saveText: { _ in },
        saveImage: { _, _ in }
    )

    static let unimplemented: Self = .init(
        url: XCTestDynamicOverlay.unimplemented("\(Self.self).url"),
        changeCount: XCTestDynamicOverlay.unimplemented("\(Self.self).changeCount"),
        saveText: XCTestDynamicOverlay.unimplemented("\(Self.self).saveText"),
        saveImage: XCTestDynamicOverlay.unimplemented("\(Self.self).saveImage")
    )
}
