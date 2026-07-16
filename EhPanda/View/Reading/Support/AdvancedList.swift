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
    private static var scrollIdleDelay: TimeInterval { 0.2 }

    @GestureState private var isUserDragging = false
    @State private var visiblePageFrames = [Int: CGRect]()
    @State private var viewportSize = CGSize.zero
    @State private var isUserScrollActive = false
    @State private var isProgrammaticScrollActive = false
    @State private var programmaticScrollTargetID: Int?
    @State private var pageIndexWrittenByUserScroll: Int?
    @State private var idleGeneration = UUID()

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
                    .onAppear {
                        viewportSize = viewportGeometry.size
                        performProgrammaticScroll(to: pagerModel.index + 1, proxy: proxy)
                    }
                }
                .coordinateSpace(name: coordinateSpaceName)
                .simultaneousGesture(userScrollGesture)
                .onChange(of: isUserDragging) { isDragging in
                    if isDragging {
                        beginUserScroll()
                    } else if isUserScrollActive {
                        scheduleIdleResolution()
                    }
                }
                .onChange(of: viewportGeometry.size) { newSize in
                    viewportSize = newSize
                }
                .onPreferenceChange(VisiblePagePreferenceKey.self) { frames in
                    visiblePageFrames = frames
                    handleGeometryChange(proxy: proxy)
                }
                .onChange(of: pagerModel.index) { newValue in
                    handlePageIndexChange(newValue, proxy: proxy)
                }
            }
        }
    }

    private var userScrollGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($isUserDragging) { _, isDragging, _ in
                isDragging = true
            }
    }

    private func beginUserScroll() {
        invalidateIdleResolution()
        isProgrammaticScrollActive = false
        programmaticScrollTargetID = nil
        isUserScrollActive = true
    }

    private func visiblePageValue(index: Element, geometry: GeometryProxy) -> [Int: CGRect] {
        guard let pageNumber = index as? Int else { return [:] }
        return [pageNumber: geometry.frame(in: .named(coordinateSpaceName))]
    }

    private func handleGeometryChange(proxy: ScrollViewProxy) {
        // Image decoding changes cell heights too. Geometry is therefore only allowed to
        // affect the current page while a real user scroll is in progress, or to settle a
        // programmatic scroll without writing anything back to the page model.
        guard !isUserDragging else { return }
        if isProgrammaticScrollActive {
            // Cells above the target keep resizing while their images arrive, which shifts
            // the content offset out from under the one-shot scroll. Re-issuing the same
            // scroll is a no-op once layout settles, so pin the target until idle.
            if let targetID = programmaticScrollTargetID {
                proxy.scrollTo(targetID, anchor: .center)
            }
            scheduleIdleResolution()
            return
        }
        if isUserScrollActive {
            scheduleIdleResolution()
            return
        }
        reanchorIfCurrentPageDrifted(proxy: proxy)
    }

    // While nobody is scrolling, the page model owns the viewport. iOS 16 does not
    // compensate the content offset when cells above the viewport change height, so a
    // burst of image loads can silently carry the list back toward the first page.
    private func reanchorIfCurrentPageDrifted(proxy: ScrollViewProxy) {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        guard viewport.width > 0, viewport.height > 0 else { return }
        let currentID = pagerModel.index + 1
        if let frame = visiblePageFrames[currentID],
           !frame.isNull, !frame.isEmpty, frame.intersects(viewport) {
            return
        }
        performProgrammaticScroll(to: currentID, proxy: proxy)
    }

    private func handlePageIndexChange(_ newValue: Int, proxy: ScrollViewProxy) {
        if pageIndexWrittenByUserScroll == newValue {
            pageIndexWrittenByUserScroll = nil
            return
        }
        pageIndexWrittenByUserScroll = nil
        performProgrammaticScroll(to: newValue + 1, proxy: proxy)
    }

    private func performProgrammaticScroll(to id: Int, proxy: ScrollViewProxy) {
        invalidateIdleResolution()
        isUserScrollActive = false
        isProgrammaticScrollActive = true
        programmaticScrollTargetID = id
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .center)
            scheduleIdleResolution()
        }
    }

    private func scheduleIdleResolution() {
        let generation = UUID()
        idleGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollIdleDelay) {
            guard idleGeneration == generation, !isUserDragging else { return }

            if isProgrammaticScrollActive {
                // Slider/page jumps own the model value. Once the scroll settles, do not
                // derive a potentially different value from transient image geometry.
                isProgrammaticScrollActive = false
                programmaticScrollTargetID = nil
                return
            }

            guard isUserScrollActive else { return }
            isUserScrollActive = false
            updatePageFromSettledUserScroll()
        }
    }

    private func invalidateIdleResolution() {
        idleGeneration = UUID()
    }

    private func updatePageFromSettledUserScroll() {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        guard viewport.width > 0, viewport.height > 0 else { return }

        let viewportCenterY = viewport.midY
        let pageNumber = visiblePageFrames
            .filter { _, frame in
                !frame.isNull && !frame.isEmpty && frame.intersects(viewport)
            }
            .min { lhs, rhs in
                abs(lhs.value.midY - viewportCenterY) < abs(rhs.value.midY - viewportCenterY)
            }?
            .key

        guard let pageNumber else { return }
        let newIndex = pageNumber - 1
        guard pagerModel.index != newIndex else { return }

        // Mark the write before publishing it so the resulting onChange does not recenter
        // the list and form a page-model/scroll-position feedback loop.
        pageIndexWrittenByUserScroll = newIndex
        pagerModel.update(.new(index: newIndex))
    }
}

private struct VisiblePagePreferenceKey: PreferenceKey {
    static var defaultValue = [Int: CGRect]()

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
