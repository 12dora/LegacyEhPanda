//
//  LiveTextView.swift
//  EhPanda
//
//  Created by xioxin on 2022/2/12.
//

import SwiftUI

struct LiveTextView: View {
    private let liveTextGroups: [LiveTextGroup]
    private let focusedLiveTextGroup: LiveTextGroup?
    private let tapAction: (LiveTextGroup) -> Void

    init(
        liveTextGroups: [LiveTextGroup],
        focusedLiveTextGroup: LiveTextGroup?,
        tapAction: @escaping (LiveTextGroup) -> Void
    ) {
        self.liveTextGroups = liveTextGroups
        self.focusedLiveTextGroup = focusedLiveTextGroup
        self.tapAction = tapAction
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let width = size.width
            let height = size.height
            ZStack {
                Canvas { context, _ in
                    context.fill(
                        Path(CGRect(x: 0, y: 0, width: width, height: height)),
                        with: .color(.black.opacity(0.1))
                    )
                    let tuples: [(UUID, Path)] = liveTextGroups
                        .flatMap { group in
                            group.blocks.map { block in
                                (group.id, block)
                            }
                        }
                        .map { (id, block) in
                            let expandingSize = 4.0
                            let bounds = block.bounds
                            let topLeft = bounds.topLeft * size
                            let rect = CGRect(
                                x: 0, y: 0,
                                width: bounds.getWidth(size) + expandingSize * 2,
                                height: bounds.getHeight(size) + expandingSize * 2)

                            let path = Path(roundedRect: rect, cornerRadius: bounds.getHeight(size) / 5)
                                .applying(CGAffineTransform(rotationAngle: block.bounds.getRadian(size)))
                                .offsetBy(dx: topLeft.x - expandingSize, dy: topLeft.y - expandingSize)
                            return (id, path)
                        }
                    context.withCGContext { cgContext in
                        tuples.forEach { (_, path) in
                            cgContext.setFillColor(.init(red: 255, green: 255, blue: 255, alpha: 1))
                            cgContext.setShadow(
                                offset: .zero, blur: 15,
                                color: .init(red: 0, green: 0, blue: 0, alpha: 0.3)
                            )
                            cgContext.addPath(path.cgPath)
                            cgContext.drawPath(using: .fill)
                        }
                    }
                    context.blendMode = .destinationOut
                    tuples.forEach { (_, path) in
                        context.fill(path, with: .color(.red))
                        context.stroke(path, with: .color(.red))
                    }

                    if let focusedLiveTextGroup = focusedLiveTextGroup {
                        context.blendMode = .copy
                        tuples.forEach { (groupUUID, path) in
                            if groupUUID == focusedLiveTextGroup.id {
                                context.stroke(
                                    path, with: .color(.accentColor.opacity(0.6)),
                                    style: .init(lineWidth: 10)
                                )
                            }
                        }
                        context.blendMode = .destinationOut
                        tuples.forEach { (groupUUID, path) in
                            if groupUUID == focusedLiveTextGroup.id {
                                context.fill(path, with: .color(.accentColor))
                            }
                        }
                    }
                }
                // Only the recognized rectangles may take touches. The canvas covers the
                // whole page, and letting it hit-test would put a transparent wall
                // between the reader's tap/zoom gestures and the image below it.
                .allowsHitTesting(false)

                ForEach(liveTextGroups) { textGroup in
                    HighlightView(text: textGroup.text) {
                        tapAction(textGroup)
                    }
                    .frame(width: textGroup.width * width, height: textGroup.height * height)
                    .position(
                        x: (textGroup.minX + textGroup.width / 2) * width,
                        y: (textGroup.minY + textGroup.height / 2) * height
                    )
                }
            }
        }
    }
}

// MARK: HighlightView
private struct HighlightView: UIViewRepresentable {
    final class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        var textView: UITextView?
        var editMenuInteraction: UIEditMenuInteraction?
        var highLightView: HighlightView

        init(_ highLightView: HighlightView) {
            self.highLightView = highLightView
        }

        @objc func onTap(sender: UITapGestureRecognizer) {
            Logger.info("onTap", context: ["tappedText": textView?.text])
            guard let textView = textView else { return }

            highLightView.tapAction()
            // Select the recognized text and hand it to the public edit menu, which
            // gathers Copy / Look Up / Translate from the responder chain and simply
            // omits whatever the device cannot offer. The previous implementation
            // performed the private `_translate:` selector unguarded, which is both an
            // App Store risk and an Objective-C exception wherever it does not exist.
            textView.becomeFirstResponder()
            textView.selectAll(nil)
            guard let editMenuInteraction = editMenuInteraction else { return }
            let configuration = UIEditMenuConfiguration(
                identifier: nil, sourcePoint: sender.location(in: textView)
            )
            editMenuInteraction.presentEditMenu(with: configuration)
        }
    }

    private let text: String
    private let tapAction: () -> Void

    init(text: String, tapAction: @escaping () -> Void) {
        self.text = text
        self.tapAction = tapAction
    }

    // Emoji presentation scalars are dropped: they carry no translatable content and
    // break up the selection the edit menu operates on.
    private var sanitizedText: String {
        text.unicodeScalars
            .filter { !$0.properties.isEmojiPresentation }
            .reduce("") { $0 + String($1) }
    }

    func makeCoordinator() -> Coordinator {
        .init(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        context.coordinator.textView = textView
        textView.text = sanitizedText
        textView.isEditable = false
        textView.tintColor = .clear
        textView.textColor = .clear
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 0)
        textView.autocapitalizationType = .sentences
        textView.isSelectable = true
        textView.isUserInteractionEnabled = true
        // These views sit on top of the pager and the zoom surface. A text view is a
        // scroll view, so every recognized rectangle installed its own pan recognizer
        // and swallowed page swipes and zoom pans that happened to start on text.
        // Selection needs neither scrolling nor panning, so both are switched off — the
        // selection and edit-menu interactions are untouched.
        textView.isScrollEnabled = false
        textView.panGestureRecognizer.isEnabled = false

        let editMenuInteraction = UIEditMenuInteraction(delegate: context.coordinator)
        textView.addInteraction(editMenuInteraction)
        context.coordinator.editMenuInteraction = editMenuInteraction

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.onTap(sender:))
        )
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.highLightView = self
        // Reassigning the text clears the selection, so recycled cells only rewrite it
        // when the recognized string actually changed.
        let newText = sanitizedText
        if uiView.text != newText {
            uiView.text = newText
        }
    }
}

// MARK: Definition
private func * (lhs: CGPoint, rhs: CGSize) -> CGPoint {
    .init(x: lhs.x * rhs.width, y: lhs.y * rhs.height)
}
