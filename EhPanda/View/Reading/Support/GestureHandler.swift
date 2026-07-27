//
//  GestureHandler.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/09.
//

import SwiftUI

final class GestureHandler: ObservableObject {
    @Published var scaleAnchor: UnitPoint = .center
    @Published var scale: Double = 1
    @Published var offset: CGSize = .zero
    // Interactive samples must not be implicitly animated: animating every pinch/pan
    // sample makes the transform chase the finger instead of tracking it. Pinch and pan
    // are tracked separately because the reader runs them simultaneously.
    @Published private(set) var isInteracting = false
    @Published private var baseScale: Double = 1
    @Published private var newOffset: CGSize = .zero
    private var isMagnifying = false
    private var isPanning = false

    private func edgeWidth(x: Double) -> Double {
        let marginW = DeviceUtil.absWindowW * (scale - 1) / 2
        let leadingMargin = scaleAnchor.x / 0.5 * marginW
        let trailingMargin = (1 - scaleAnchor.x) / 0.5 * marginW
        return min(max(x, -trailingMargin), leadingMargin)
    }
    private func edgeHeight(y: Double) -> Double {
        let marginH = DeviceUtil.absWindowH * (scale - 1) / 2
        let topMargin = scaleAnchor.y / 0.5 * marginH
        let bottomMargin = (1 - scaleAnchor.y) / 0.5 * marginH
        return min(max(y, -bottomMargin), topMargin)
    }
    private func correctOffset() {
        offset.width = edgeWidth(x: offset.width)
        offset.height = edgeHeight(y: offset.height)
    }
    private func correctScaleAnchor(point: CGPoint) {
        let x = min(1, max(0, point.x / DeviceUtil.absWindowW))
        let y = min(1, max(0, point.y / DeviceUtil.absWindowH))
        scaleAnchor = .init(x: x, y: y)
    }
    private func setOffset(_ offset: CGSize) {
        self.offset = offset
        correctOffset()
    }
    private func setScale(scale: Double, maximum: Double) {
        guard scale >= 1 && scale <= maximum else { return }
        self.scale = scale
        correctOffset()
    }

    // One place that returns the reader to 1x, and one place that re-bases the
    // incremental gesture values. Double tap used to leave `newOffset`/`baseScale`
    // behind, so the next drag or pinch jumped from a stale origin.
    private func resetTransform() {
        scale = 1
        baseScale = 1
        offset = .zero
        newOffset = .zero
        scaleAnchor = .center
    }
    private func synchronizeGestureBase() {
        baseScale = scale
        newOffset = scale > 1 ? offset : .zero
    }
    private func endAllGesturePhases() {
        isMagnifying = false
        isPanning = false
        updateInteracting()
    }
    private func updateInteracting() {
        let newValue = isMagnifying || isPanning
        guard isInteracting != newValue else { return }
        isInteracting = newValue
    }

    func onSingleTapGestureEnded(
        readingDirection: ReadingDirection,
        setPageIndexOffsetAction: @escaping (Int) -> Void,
        toggleShowsPanelAction: @escaping () -> Void
    ) {
        Logger.info("onSingleTapGestureEnded", context: ["readingDirection": readingDirection])
        endAllGesturePhases()
        guard readingDirection != .vertical,
              let pointX = TouchHandler.shared.currentPoint?.x
        else {
            toggleShowsPanelAction()
            return
        }
        let rightToLeft = readingDirection == .rightToLeft
        if pointX < DeviceUtil.absWindowW * 0.2 {
            setPageIndexOffsetAction(rightToLeft ? 1 : -1)
        } else if pointX > DeviceUtil.absWindowW * (1 - 0.2) {
            setPageIndexOffsetAction(rightToLeft ? -1 : 1)
        } else {
            toggleShowsPanelAction()
        }
    }

    func onDoubleTapGestureEnded(scaleMaximum: Double, doubleTapScale: Double) {
        Logger.info("onDoubleTapGestureEnded", context: [
            "scaleMaximum": scaleMaximum, "doubleTapScale": doubleTapScale
        ])
        endAllGesturePhases()
        guard scale == 1 else {
            resetTransform()
            return
        }
        if let point = TouchHandler.shared.currentPoint {
            correctScaleAnchor(point: point)
        }
        setOffset(.zero)
        setScale(scale: doubleTapScale, maximum: scaleMaximum)
        synchronizeGestureBase()
    }

    func onMagnificationGestureChanged(value: Double, scaleMaximum: Double) {
        // MagnificationGesture does not guarantee an exact 1 for its first sample, so
        // the base scale is captured from the gesture phase instead of from the value.
        if !isMagnifying {
            isMagnifying = true
            baseScale = scale
            updateInteracting()
        }
        if let point = TouchHandler.shared.currentPoint {
            correctScaleAnchor(point: point)
        }
        setScale(scale: value * baseScale, maximum: scaleMaximum)
    }

    func onMagnificationGestureEnded(value: Double, scaleMaximum: Double) {
        Logger.info("onMagnificationGestureEnded", context: [
            "value": value, "scaleMaximum": scaleMaximum
        ])
        onMagnificationGestureChanged(value: value, scaleMaximum: scaleMaximum)
        isMagnifying = false
        updateInteracting()
        if scale - 1 < 0.01 {
            resetTransform()
        } else {
            synchronizeGestureBase()
        }
    }

    func onDragGestureChanged(value: DragGesture.Value) {
        guard scale > 1 else { return }
        if !isPanning {
            isPanning = true
            updateInteracting()
        }
        let newX = value.translation.width + newOffset.width
        let newY = value.translation.height + newOffset.height
        let newOffsetW = edgeWidth(x: newX)
        let newOffsetH = edgeHeight(y: newY)
        setOffset(.init(width: newOffsetW, height: newOffsetH))
    }

    func onDragGestureEnded(value: DragGesture.Value) {
        Logger.info("onDragGestureEnded", context: ["value": value])
        onDragGestureChanged(value: value)
        isPanning = false
        updateInteracting()
        synchronizeGestureBase()
    }

    func onControlPanelDismissGestureEnded(value: DragGesture.Value, dismissAction: @escaping () -> Void) {
        Logger.info("onControlPanelDismissGestureEnded", context: ["value": value])
        if value.predictedEndTranslation.height > 30 {
            dismissAction()
        }
    }
}
