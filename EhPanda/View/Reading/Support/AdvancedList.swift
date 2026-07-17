//
//  AdvancedList.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/07/30.
//

import SwiftUI
import SwiftUIPager

struct AdvancedList<Element, ID, PageView, G>: View
where PageView: View, Element: Equatable, ID: Hashable, G: Gesture {
    @StateObject private var scrollCoordinator = AdvancedListScrollCoordinator()

    private let coordinateSpaceName = "EhPanda.AdvancedList"
    private let pagerModel: Page
    private let data: [Element]
    private let id: KeyPath<Element, ID>
    private let spacing: CGFloat
    private let gesture: G
    private let content: (Element) -> PageView

    init<Data: RandomAccessCollection>(
        page: Page, data: Data,
        id: KeyPath<Element, ID>, spacing: CGFloat, gesture: G,
        @ViewBuilder content: @escaping (Element) -> PageView
    ) where Data.Index == Int, Data.Element == Element {
        self.pagerModel = page
        self.data = .init(data)
        self.id = id
        self.spacing = spacing
        self.gesture = gesture
        self.content = content
    }

    var body: some View {
        GeometryReader { viewportGeometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: spacing) {
                        ForEach(data, id: id) { index in
                            content(index)
                                .simultaneousGesture(gesture)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: VisiblePagePreferenceKey.self,
                                            value: visiblePageValue(index: index, geometry: geometry)
                                        )
                                    }
                                }
                        }
                    }
                    .background(ScrollViewIntrospector(onResolve: scrollCoordinator.attach))
                    .onAppear {
                        scrollCoordinator.viewportSize = viewportGeometry.size
                        scrollCoordinator.beginJump(
                            to: pagerModel.index + 1,
                            positionRatio: positionRatio(pageID: pagerModel.index + 1),
                            proxy: proxy
                        )
                    }
                }
                .coordinateSpace(name: coordinateSpaceName)
                .onChange(of: viewportGeometry.size) { newSize in
                    scrollCoordinator.viewportSize = newSize
                }
                .onPreferenceChange(VisiblePagePreferenceKey.self) { frames in
                    scrollCoordinator.handleFrames(frames, pagerModel: pagerModel, proxy: proxy)
                }
                .onChange(of: pagerModel.index) { newValue in
                    scrollCoordinator.handleModelIndexChange(
                        newValue, positionRatio: positionRatio(pageID: newValue + 1), proxy: proxy
                    )
                }
            }
        }
    }

    private func visiblePageValue(index: Element, geometry: GeometryProxy) -> [Int: CGRect] {
        guard let pageNumber = index as? Int else { return [:] }
        return [pageNumber: geometry.frame(in: .named(coordinateSpaceName))]
    }

    // Relative position of a page inside the whole list, used to estimate a content
    // offset when jumping into a region the LazyVStack has never materialized.
    private func positionRatio(pageID: Int) -> Double? {
        guard !data.isEmpty, let position = data.firstIndex(where: { ($0 as? Int) == pageID })
        else { return nil }
        return (.init(position) + 0.5) / .init(data.count)
    }
}

// The iOS 16 ScrollView keeps a numeric content offset when cells resize, so an image
// finishing above the viewport visually shoves the reader back toward the first page,
// and its pan gesture cancels any simultaneous SwiftUI DragGesture, so user scrolling
// cannot be detected reliably from gestures. This coordinator therefore talks to the
// underlying UIScrollView directly: it compensates the offset by exactly the height
// change that happened above the top edge, derives the current page from the frames
// nearest the viewport center, and only ever scrolls programmatically for explicit
// jumps (progress restore, slider, tap page-flip, autoplay), which a user touch on the
// scroll view immediately cancels.
final class AdvancedListScrollCoordinator: ObservableObject {
    // No @Published on purpose: nothing here drives SwiftUI rendering.
    var viewportSize: CGSize = .zero

    private weak var scrollView: UIScrollView?
    private var latestFrames = [Int: CGRect]()
    private var pageIndexWrittenByTracking: Int?

    private var pinnedPageID: Int?
    private var pinnedPositionRatio: Double?
    private var pinnedProxy: ScrollViewProxy?
    private var pinAttempts = 0
    private var pinSettledPasses = 0
    private var pinDeadlineRetries = 0
    private var pinGeneration = UUID()

    private static let pinMaxAttempts = 40
    private static let pinMaxDeadlineRetries = 2
    private static let pinDeadline: TimeInterval = 0.6
    private static let pinSettledPassesNeeded = 2

    func attach(scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
    }

    func handleFrames(_ frames: [Int: CGRect], pagerModel: Page, proxy: ScrollViewProxy) {
        let previousFrames = latestFrames
        latestFrames = frames

        if pinnedPageID != nil {
            continuePin(proxy: proxy)
            return
        }
        // When the offset was corrected, the received frames predate the correction;
        // deriving a page from them would be off by the correction. The adjustment
        // itself produces a follow-up frames pass that tracks from consistent data.
        if compensateForHeightChanges(from: previousFrames, to: frames) { return }
        trackCurrentPage(pagerModel: pagerModel)
    }

    func handleModelIndexChange(_ newIndex: Int, positionRatio: Double?, proxy: ScrollViewProxy) {
        if pageIndexWrittenByTracking == newIndex {
            pageIndexWrittenByTracking = nil
            return
        }
        pageIndexWrittenByTracking = nil
        // Fast scrolling can outrun onChange coalescing and stale the marker; a value
        // that already matches the viewport needs no jump regardless of who wrote it.
        if newIndex == derivedCenterPageID().map({ $0 - 1 }) { return }
        beginJump(to: newIndex + 1, positionRatio: positionRatio, proxy: proxy)
    }

    // MARK: Offset compensation

    private func compensateForHeightChanges(from old: [Int: CGRect], to new: [Int: CGRect]) -> Bool {
        guard let scrollView else { return false }
        var delta: CGFloat = 0
        for (pageID, newFrame) in new {
            guard let oldFrame = old[pageID] else { continue }
            let heightChange = newFrame.height - oldFrame.height
            // Only cells entirely above the top edge shift the visible content; a
            // partially visible cell keeps its own top edge fixed while it resizes,
            // and cells below the viewport cannot move anything the user can see.
            guard abs(heightChange) > 0.5, oldFrame.maxY <= 1 else { continue }
            delta += heightChange
        }
        guard abs(delta) > 0.5 else { return false }
        let target = clampedOffsetY(scrollView.contentOffset.y + delta, in: scrollView)
        guard abs(target - scrollView.contentOffset.y) > 0.5 else { return false }
        scrollView.contentOffset.y = target
        return true
    }

    private func clampedOffsetY(_ offsetY: CGFloat, in scrollView: UIScrollView) -> CGFloat {
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(
            minY,
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                - scrollView.bounds.height
        )
        return min(max(offsetY, minY), maxY)
    }

    // MARK: Page tracking

    private func derivedCenterPageID() -> Int? {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        return latestFrames
            .filter { _, frame in !frame.isNull && !frame.isEmpty && frame.intersects(viewport) }
            .min { abs($0.value.midY - viewport.midY) < abs($1.value.midY - viewport.midY) }?
            .key
    }

    private func trackCurrentPage(pagerModel: Page) {
        guard let currentPageID = derivedCenterPageID() else { return }
        let newIndex = currentPageID - 1
        guard pagerModel.index != newIndex else { return }
        // Mark the write before publishing it so the resulting onChange is recognized
        // as a reflection of the viewport instead of a jump request.
        pageIndexWrittenByTracking = newIndex
        pagerModel.update(.new(index: newIndex))
    }

    // MARK: Explicit jumps

    func beginJump(to pageID: Int, positionRatio: Double?, proxy: ScrollViewProxy) {
        pinnedPageID = pageID
        pinnedPositionRatio = positionRatio
        pinnedProxy = proxy
        pinAttempts = 0
        pinSettledPasses = 0
        pinDeadlineRetries = 0
        proxy.scrollTo(pageID, anchor: .center)
        schedulePinDeadline()
    }

    private func continuePin(proxy: ScrollViewProxy) {
        guard let target = pinnedPageID else { return }
        // The user always wins: touching the scroll view cancels any pending jump.
        if let scrollView, scrollView.isTracking || scrollView.isDragging {
            endPin()
            return
        }
        if isPinTargetSettled(target) {
            pinSettledPasses += 1
            if pinSettledPasses >= Self.pinSettledPassesNeeded { endPin() }
            return
        }
        pinSettledPasses = 0
        pinAttempts += 1
        guard pinAttempts <= Self.pinMaxAttempts else {
            endPin()
            return
        }
        // scrollTo into a far, never-materialized LazyVStack region is unreliable on
        // iOS 16; drop the offset near the target by content-size ratio so the cells
        // materialize, then let subsequent passes center it precisely.
        if latestFrames[target] == nil, pinAttempts >= 3 {
            applyEstimatedOffset()
        }
        proxy.scrollTo(target, anchor: .center)
    }

    private func isPinTargetSettled(_ target: Int) -> Bool {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        guard viewport.height > 0, let frame = latestFrames[target],
              !frame.isNull, !frame.isEmpty
        else { return false }
        if abs(frame.midY - viewport.midY) <= max(24, frame.height * 0.25) { return true }
        // First and last pages cannot be centered; reaching the offset boundary with
        // the target visible is as settled as it gets.
        return frame.intersects(viewport) && isAtOffsetBoundary
    }

    private var isAtOffsetBoundary: Bool {
        guard let scrollView else { return true }
        let offsetY = scrollView.contentOffset.y
        return offsetY <= -scrollView.adjustedContentInset.top + 1
            || offsetY >= clampedOffsetY(.greatestFiniteMagnitude, in: scrollView) - 1
    }

    private func applyEstimatedOffset() {
        guard let scrollView, let ratio = pinnedPositionRatio,
              scrollView.contentSize.height > 0
        else { return }
        let estimated = scrollView.contentSize.height * ratio - scrollView.bounds.height / 2
        scrollView.contentOffset.y = clampedOffsetY(estimated, in: scrollView)
    }

    private func schedulePinDeadline() {
        let generation = UUID()
        pinGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pinDeadline) { [weak self] in
            guard let self, self.pinGeneration == generation, let target = self.pinnedPageID
            else { return }
            // No frames event has settled the pin. Without new layout passes the
            // per-event retries never run, so retry from the timer a bounded number
            // of times (covers scrollTo being silently dropped mid-layout), then
            // give up rather than fight whatever state the list is in.
            if self.isPinTargetSettled(target) || self.pinDeadlineRetries >= Self.pinMaxDeadlineRetries {
                self.endPin()
                return
            }
            self.pinDeadlineRetries += 1
            if self.latestFrames[target] == nil {
                self.applyEstimatedOffset()
            }
            self.pinnedProxy?.scrollTo(target, anchor: .center)
            self.schedulePinDeadline()
        }
    }

    private func endPin() {
        pinnedPageID = nil
        pinnedPositionRatio = nil
        pinnedProxy = nil
        pinGeneration = UUID()
    }
}

// Resolves the UIScrollView backing the SwiftUI ScrollView by walking up from a
// zero-sized view injected into the scroll content.
private struct ScrollViewIntrospector: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> IntrospectionView {
        let view = IntrospectionView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: IntrospectionView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfNeeded()
    }

    final class IntrospectionView: UIView {
        var onResolve: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfNeeded()
        }

        func resolveIfNeeded() {
            guard window != nil else { return }
            if let scrollView = enclosingScrollView() {
                onResolve?(scrollView)
                return
            }
            // The hierarchy may still be assembling; retry once it has settled.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil,
                      let scrollView = self.enclosingScrollView()
                else { return }
                self.onResolve?(scrollView)
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var current = superview
            while let view = current {
                if let scrollView = view as? UIScrollView { return scrollView }
                current = view.superview
            }
            return nil
        }
    }
}

private struct VisiblePagePreferenceKey: PreferenceKey {
    static var defaultValue = [Int: CGRect]()

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
