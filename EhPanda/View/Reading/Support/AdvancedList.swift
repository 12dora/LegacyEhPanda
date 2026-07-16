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
    @State var performingChanges = false
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
                .onAppear { tryScrollTo(id: pagerModel.index + 1, proxy: proxy) }
            }
            .coordinateSpace(name: coordinateSpaceName)
            .onPreferenceChange(VisiblePagePreferenceKey.self, perform: updateVisiblePage)
            .onChange(of: pagerModel.index) { newValue in
                tryScrollTo(id: newValue + 1, proxy: proxy)
            }
        }
    }

    private func visiblePageValue(index: Element, geometry: GeometryProxy) -> [Int: CGFloat] {
        guard let pageNumber = index as? Int else { return [:] }
        let frame = geometry.frame(in: .named(coordinateSpaceName))
        return [pageNumber: abs(frame.midY - DeviceUtil.absWindowH / 2)]
    }

    private func updateVisiblePage(_ values: [Int: CGFloat]) {
        guard !performingChanges,
              let pageNumber = values.min(by: { $0.value < $1.value })?.key,
              pagerModel.index != pageNumber - 1
        else { return }
        performingChanges = true
        pagerModel.update(.new(index: pageNumber - 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            performingChanges = false
        }
    }

    private func tryScrollTo(id: Int, proxy: ScrollViewProxy) {
        if !performingChanges {
            DispatchQueue.main.async {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

private struct VisiblePagePreferenceKey: PreferenceKey {
    static var defaultValue = [Int: CGFloat]()

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
