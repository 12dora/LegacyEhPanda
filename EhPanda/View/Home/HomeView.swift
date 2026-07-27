//
//  HomeView.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/12/13.
//

import SwiftUI
import Kingfisher
import SwiftUIPager
import SFSafeSymbols
import ComposableArchitecture

struct HomeView: View {
    private let store: StoreOf<HomeReducer>
    @ObservedObject private var viewStore: ViewStoreOf<HomeReducer>
    private let user: User
    @Binding private var setting: Setting
    private let blurRadius: Double
    private let tagTranslator: TagTranslator

    init(
        store: StoreOf<HomeReducer>,
        user: User, setting: Binding<Setting>, blurRadius: Double, tagTranslator: TagTranslator
    ) {
        self.store = store
        viewStore = ViewStore(store, observe: { $0 })
        self.user = user
        _setting = setting
        self.blurRadius = blurRadius
        self.tagTranslator = tagTranslator
    }

    // MARK: HomeView
    var body: some View {
        NavigationView {
            ZStack {
                ScrollView(showsIndicators: false) {
                    VStack {
                        if !viewStore.popularGalleries.isEmpty {
                            CardSlideSection(
                                galleries: viewStore.popularGalleries,
                                pageIndex: viewStore.$cardPageIndex,
                                currentID: viewStore.currentCardID,
                                colors: viewStore.cardColors,
                                navigateAction: navigateTo(gid:),
                                webImageSuccessAction: { gid, result in
                                    viewStore.send(.analyzeImageColors(gid, result))
                                }
                            )
                            .equatable().allowsHitTesting(viewStore.allowsCardHitTesting)
                        }
                        Group {
                            if viewStore.frontpageGalleries.count > 1 {
                                CoverWallSection(
                                    galleries: viewStore.frontpageGalleries,
                                    isLoading: viewStore.frontpageLoadingState == .loading,
                                    navigateAction: navigateTo(gid:),
                                    showAllAction: { viewStore.send(.setNavigation(.section(.frontpage))) },
                                    reloadAction: { viewStore.send(.fetchFrontpageGalleries) }
                                )
                            }
                            ToplistsSection(
                                galleries: viewStore.toplistsGalleries,
                                loadingStates: viewStore.toplistsLoadingState,
                                isLoading: viewStore.toplistsLoadingState.values.contains(.loading),
                                navigateAction: navigateTo(gid:),
                                showAllAction: { viewStore.send(.setNavigation(.section(.toplists))) },
                                reloadAction: { viewStore.send(.fetchAllToplistsGalleries) },
                                retryAction: { viewStore.send(.fetchToplistsGalleries($0)) }
                            )
                            MiscGridSection(navigateAction: navigateTo(type:))
                        }
                        .padding(.vertical)
                    }
                }
                // Sections are independent requests, so the scroll is shown as soon as any of
                // them has content instead of being gated on Popular alone.
                .opacity(viewStore.hasAnySectionContent ? 1 : 0).zIndex(2)
                LoadingView()
                    .opacity(
                        viewStore.isAnySectionLoading
                        && !viewStore.hasAnySectionContent ? 1 : 0
                    )
                    .zIndex(0)
                let error = viewStore.firstSectionError
                ErrorView(error: error ?? .unknown) {
                    viewStore.send(.fetchAllGalleries)
                }
                .opacity(
                    !viewStore.hasAnySectionContent
                    && !viewStore.isAnySectionLoading && error != nil ? 1 : 0
                )
                .zIndex(1)
            }
            .sheet(
                unwrapping: viewStore.$route,
                case: /HomeReducer.Route.detail,
                isEnabled: DeviceUtil.isPad
            ) { route in
                NavigationView {
                    DetailView(
                        store: store.scope(state: \.detailState, action: HomeReducer.Action.detail),
                        gid: route.wrappedValue, user: user, setting: $setting,
                        blurRadius: blurRadius, tagTranslator: tagTranslator
                    )
                }
                .autoBlur(radius: blurRadius).environment(\.inSheet, true).navigationViewStyle(.stack)
            }
            .animation(.default, value: viewStore.isAnySectionLoading)
            .onAppear {
                if !viewStore.hasAnySectionContent {
                    viewStore.send(.fetchAllGalleries)
                }
            }
            .background(navigationLinks)
            .toolbar(content: toolbar)
            .navigationTitle(L10n.Localizable.HomeView.Title.home)
        }
    }

    private func toolbar() -> some ToolbarContent {
        CustomToolbarItem(tint: .primary) {
            Button {
                viewStore.send(.fetchAllGalleries)
            } label: {
                Image(systemSymbol: .arrowCounterclockwise)
            }
            .opacity(viewStore.isAnySectionLoading ? 0 : 1)
            .overlay(ProgressView().opacity(viewStore.isAnySectionLoading ? 1 : 0))
        }
    }
}

// MARK: NavigationLinks
private extension HomeView {
    @ViewBuilder var navigationLinks: some View {
        if DeviceUtil.isPhone {
            detailViewLink
        }
        miscGridLink
        sectionLink
    }
    var detailViewLink: some View {
        NavigationLink(unwrapping: viewStore.$route, case: /HomeReducer.Route.detail) { route in
            DetailView(
                store: store.scope(state: \.detailState, action: HomeReducer.Action.detail),
                gid: route.wrappedValue, user: user, setting: $setting,
                blurRadius: blurRadius, tagTranslator: tagTranslator
            )
        }
    }
    var miscGridLink: some View {
        NavigationLink(unwrapping: viewStore.$route, case: /HomeReducer.Route.misc) { route in
            switch route.wrappedValue {
            case .popular:
                PopularView(
                    store: store.scope(state: \.popularState, action: HomeReducer.Action.popular),
                    user: user, setting: $setting, blurRadius: blurRadius, tagTranslator: tagTranslator
                )
            case .watched:
                WatchedView(
                    store: store.scope(state: \.watchedState, action: HomeReducer.Action.watched),
                    user: user, setting: $setting, blurRadius: blurRadius, tagTranslator: tagTranslator
                )
            case .history:
                HistoryView(
                    store: store.scope(state: \.historyState, action: HomeReducer.Action.history),
                    user: user, setting: $setting, blurRadius: blurRadius, tagTranslator: tagTranslator
                )
            }
        }
    }
    var sectionLink: some View {
        NavigationLink(unwrapping: viewStore.$route, case: /HomeReducer.Route.section) { route in
            switch route.wrappedValue {
            case .frontpage:
                FrontpageView(
                    store: store.scope(state: \.frontpageState, action: HomeReducer.Action.frontpage),
                    user: user, setting: $setting, blurRadius: blurRadius, tagTranslator: tagTranslator
                )
            case .toplists:
                ToplistsView(
                    store: store.scope(state: \.toplistsState, action: HomeReducer.Action.toplists),
                    user: user, setting: $setting, blurRadius: blurRadius, tagTranslator: tagTranslator
                )
            }
        }
    }
    func navigateTo(gid: String) {
        viewStore.send(.setNavigation(.detail(gid)))
    }
    func navigateTo(type: HomeMiscGridType) {
        viewStore.send(.setNavigation(.misc(type)))
    }
}

// MARK: CardSlideSection
private struct CardSlideSection: View, Equatable {
    @StateObject private var page: Page = .withIndex(1)
    @Binding private var pageIndex: Int

    private let galleries: [Gallery]
    private let currentID: String
    private let colors: [Color]
    private let navigateAction: (String) -> Void
    private let webImageSuccessAction: (String, RetrieveImageResult) -> Void

    init(
        galleries: [Gallery], pageIndex: Binding<Int>, currentID: String,
        colors: [Color], navigateAction: @escaping (String) -> Void,
        webImageSuccessAction: @escaping (String, RetrieveImageResult) -> Void
    ) {
        self.galleries = galleries
        _pageIndex = pageIndex
        self.currentID = currentID
        self.colors = colors
        self.navigateAction = navigateAction
        self.webImageSuccessAction = webImageSuccessAction
    }

    static func == (lhs: CardSlideSection, rhs: CardSlideSection) -> Bool {
        lhs.galleries == rhs.galleries
        && lhs.currentID == rhs.currentID
        && lhs.colors == rhs.colors
    }

    var body: some View {
        Pager(page: page, data: galleries) { gallery in
            Button {
                navigateAction(gallery.id)
            } label: {
                GalleryCardCell(gallery: gallery, currentID: currentID, colors: colors) {
                    webImageSuccessAction(gallery.gid, $0)
                }
                .tint(.primary).multilineTextAlignment(.leading)
            }
        }
        .preferredItemSize(Defaults.FrameSize.cardCellSize)
        .interactive(opacity: 0.2).itemSpacing(20)
        .loopPages().pagingPriority(.high)
        .synchronize($pageIndex, $page.index)
        .frame(height: Defaults.FrameSize.cardCellHeight)
    }
}

// MARK: CoverWallSection
private struct CoverWallSection: View {
    private let galleries: [Gallery]
    private let isLoading: Bool
    private let navigateAction: (String) -> Void
    private let showAllAction: () -> Void
    private let reloadAction: () -> Void

    init(
        galleries: [Gallery], isLoading: Bool,
        navigateAction: @escaping (String) -> Void,
        showAllAction: @escaping () -> Void,
        reloadAction: @escaping () -> Void
    ) {
        self.galleries = galleries
        self.isLoading = isLoading
        self.navigateAction = navigateAction
        self.showAllAction = showAllAction
        self.reloadAction = reloadAction
    }

    private var dataSource: [[Gallery]] {
        var galleries = galleries
        if galleries.isEmpty {
            galleries = Gallery.mockGalleries(count: 25)
        }
        if galleries.count % 2 != 0 { galleries = galleries.dropLast() }
        return stride(from: 0, to: galleries.count, by: 2).map { index in
            [galleries[index], galleries[index + 1]]
        }
    }

    var body: some View {
        SubSection(
            title: L10n.Localizable.HomeView.Section.Title.frontpage,
            tint: .secondary, isLoading: isLoading,
            reloadAction: reloadAction,
            showAllAction: showAllAction
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(dataSource, id: \.first) {
                        VerticalCoverStack(galleries: $0, navigateAction: navigateAction)
                    }
                    .withHorizontalSpacing(width: 0)
                }
            }
            .frame(height: Defaults.ImageSize.rowH * 2 + 30)
        }
    }
}

private struct VerticalCoverStack: View {
    private let galleries: [Gallery]
    private let navigateAction: (String) -> Void

    init(galleries: [Gallery], navigateAction: @escaping (String) -> Void) {
        self.galleries = galleries
        self.navigateAction = navigateAction
    }

    private func placeholder() -> some View {
        Placeholder(style: .activity(ratio: Defaults.ImageSize.headerAspect))
    }
    private func imageContainer(gallery: Gallery) -> some View {
        Button {
            navigateAction(gallery.id)
        } label: {
            KFImage(gallery.coverURL).placeholder(placeholder).defaultModifier().scaledToFill()
                .frame(width: Defaults.ImageSize.rowW, height: Defaults.ImageSize.rowH).cornerRadius(2)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            ForEach(galleries, content: imageContainer)
        }
    }
}

// MARK: ToplistsSection
private struct ToplistsSection: View {
    private let galleries: [Int: [Gallery]]
    private let loadingStates: [Int: LoadingState]
    private let isLoading: Bool
    private let navigateAction: (String) -> Void
    private let showAllAction: () -> Void
    private let reloadAction: () -> Void
    private let retryAction: (Int) -> Void

    init(
        galleries: [Int: [Gallery]], loadingStates: [Int: LoadingState], isLoading: Bool,
        navigateAction: @escaping (String) -> Void,
        showAllAction: @escaping () -> Void,
        reloadAction: @escaping () -> Void,
        retryAction: @escaping (Int) -> Void
    ) {
        self.galleries = galleries
        self.loadingStates = loadingStates
        self.isLoading = isLoading
        self.navigateAction = navigateAction
        self.showAllAction = showAllAction
        self.reloadAction = reloadAction
        self.retryAction = retryAction
    }

    private func categoryGalleries(_ type: ToplistsType) -> [Gallery] {
        galleries[type.categoryIndex] ?? []
    }
    private func rankedGalleries(_ type: ToplistsType, range: ClosedRange<Int>) -> [Gallery] {
        let source = categoryGalleries(type)
        guard source.count > range.upperBound else { return [] }
        return Array(source[range])
    }
    private func categoryError(_ type: ToplistsType) -> AppError? {
        guard case .failed(let error)? = loadingStates[type.categoryIndex] else { return nil }
        return error
    }

    var body: some View {
        SubSection(
            title: L10n.Localizable.HomeView.Section.Title.toplists,
            tint: .secondary, isLoading: isLoading,
            reloadAction: reloadAction,
            showAllAction: showAllAction
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(ToplistsType.allCases, content: verticalStacks)
                }
            }
        }
    }
    private func verticalStacks(type: ToplistsType) -> some View {
        VStack(alignment: .leading) {
            Text(type.value).font(.subheadline.bold())
            // An empty category renders an inert skeleton instead of fake galleries: a
            // `Gallery.empty` button would route a random UUID into a blank Detail.
            if categoryGalleries(type).isEmpty {
                ToplistsPlaceholderStack(
                    error: categoryError(type),
                    retryAction: { retryAction(type.categoryIndex) }
                )
            } else {
                HStack {
                    VerticalToplistsStack(
                        galleries: rankedGalleries(type, range: 0...2), startRanking: 1,
                        navigateAction: navigateAction
                    )
                    if DeviceUtil.isPad {
                        VerticalToplistsStack(
                            galleries: rankedGalleries(type, range: 3...5), startRanking: 4,
                            navigateAction: navigateAction
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 5)
    }
}

private struct ToplistsPlaceholderStack: View {
    private let error: AppError?
    private let retryAction: () -> Void

    init(error: AppError?, retryAction: @escaping () -> Void) {
        self.error = error
        self.retryAction = retryAction
    }

    private var columnCount: Int {
        DeviceUtil.isPad ? 2 : 1
    }

    private var skeleton: some View {
        HStack {
            ForEach(0..<columnCount, id: \.self) { _ in
                VStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { index in
                        VStack(spacing: 10) {
                            ToplistsSkeletonRow()
                            Divider().opacity(index == 2 ? 0 : 1)
                        }
                    }
                }
                .frame(width: Defaults.FrameSize.rankingCellWidth)
            }
        }
    }

    var body: some View {
        ZStack {
            skeleton
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(error == nil ? 1 : 0.25)
            if let error = error {
                VStack(spacing: 10) {
                    Image(systemSymbol: error.symbol).font(.title2).foregroundStyle(.gray)
                    Button(L10n.Localizable.ErrorView.Button.retry, action: retryAction)
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
        }
    }
}

private struct ToplistsSkeletonRow: View {
    private var fill: Color {
        Color(.systemGray5)
    }

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(fill)
                .frame(width: Defaults.ImageSize.rowW * 0.75, height: Defaults.ImageSize.rowH * 0.75)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(fill).frame(height: 10)
                RoundedRectangle(cornerRadius: 2).fill(fill).frame(height: 10).padding(.trailing, 40)
            }
            .padding(.leading, 10)
            Spacer()
        }
    }
}

private struct VerticalToplistsStack: View {
    private let galleries: [Gallery]
    private let startRanking: Int
    private let navigateAction: (String) -> Void

    init(galleries: [Gallery], startRanking: Int, navigateAction: @escaping (String) -> Void) {
        self.galleries = galleries
        self.startRanking = startRanking
        self.navigateAction = navigateAction
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<galleries.count, id: \.self) { index in
                VStack(spacing: 10) {
                    Button {
                        navigateAction(galleries[index].id)
                    } label: {
                        GalleryRankingCell(gallery: galleries[index], ranking: startRanking + index)
                            .tint(.primary).multilineTextAlignment(.leading)
                    }
                    Divider().opacity(index == galleries.count - 1 ? 0 : 1)
                }
            }
        }
        .frame(width: Defaults.FrameSize.rankingCellWidth)
    }
}

// MARK: MiscGridSection
private struct MiscGridSection: View {
    private let navigateAction: (HomeMiscGridType) -> Void

    init(navigateAction: @escaping (HomeMiscGridType) -> Void) {
        self.navigateAction = navigateAction
    }

    var body: some View {
        SubSection(title: L10n.Localizable.HomeView.Section.Title.other, showAll: false) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    let types = HomeMiscGridType.allCases
                    ForEach(types) { type in
                        Button {
                            navigateAction(type)
                        } label: {
                            MiscGridItem(title: type.title, symbol: type.symbol).tint(.primary)
                        }
                        .padding(.trailing, type == types.last ? 0 : 10)
                    }
                    .withHorizontalSpacing()
                }
            }
        }
    }
}

private struct MiscGridItem: View {
    private let title: String
    private let subTitle: String?
    private let symbol: SFSymbol

    init(title: String, subTitle: String? = nil, symbol: SFSymbol) {
        self.title = title
        self.subTitle = subTitle
        self.symbol = symbol
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.title2.bold()).lineLimit(1).frame(minWidth: 100)
                if let subTitle = subTitle {
                    Text(subTitle).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Image(systemSymbol: symbol).font(.system(size: 50, weight: .light, design: .default))
                .foregroundColor(.secondary).imageScale(.large).offset(x: 20, y: 20)
        }
        .padding(30).cornerRadius(15).background(Color(.systemGray6).cornerRadius(15))
    }
}

// MARK: Definition
enum HomeMiscGridType: CaseIterable, Identifiable {
    var id: String { title }

    case popular
    case watched
    case history
}

extension HomeMiscGridType {
    var title: String {
        switch self {
        case .popular:
            return L10n.Localizable.Enum.HomeMiscGridType.Title.popular
        case .watched:
            return L10n.Localizable.Enum.HomeMiscGridType.Title.watched
        case .history:
            return L10n.Localizable.Enum.HomeMiscGridType.Title.history
        }
    }
    var symbol: SFSymbol {
        switch self {
        case .popular:
            return .flame
        case .watched:
            return .tagCircle
        case .history:
            return .clockArrowCirclepath
        }
    }
}

enum HomeSectionType: String, CaseIterable, Identifiable {
    var id: String { rawValue }

    case frontpage
    case toplists
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView(
            store: .init(initialState: .init(), reducer: HomeReducer.init),
            user: .init(),
            setting: .constant(.init()),
            blurRadius: 0,
            tagTranslator: .init()
        )
    }
}
