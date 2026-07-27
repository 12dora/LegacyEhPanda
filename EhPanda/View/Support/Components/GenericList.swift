//
//  GenericList.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/07/25.
//

import SwiftUI
import SFSafeSymbols
import ComposableArchitecture

struct GenericList: View {
    private let galleries: [Gallery]
    private let setting: Setting
    private let pageNumber: PageNumber?
    private let loadingState: LoadingState
    private let footerLoadingState: LoadingState
    private let fetchAction: (() -> Void)?
    private let fetchMoreAction: (() -> Void)?
    private let navigateAction: ((String) -> Void)?
    private let translateAction: ((String) -> (String, TagTranslation?))?

    init(
        galleries: [Gallery], setting: Setting, pageNumber: PageNumber?,
        loadingState: LoadingState, footerLoadingState: LoadingState,
        fetchAction: (() -> Void)? = nil,
        fetchMoreAction: (() -> Void)? = nil,
        navigateAction: ((String) -> Void)? = nil,
        translateAction: ((String) -> (String, TagTranslation?))? = nil
    ) {
        self.galleries = galleries
        self.setting = setting
        self.pageNumber = pageNumber
        self.loadingState = loadingState
        self.footerLoadingState = footerLoadingState
        self.fetchAction = fetchAction
        self.fetchMoreAction = fetchMoreAction
        self.navigateAction = navigateAction
        self.translateAction = translateAction
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                switch setting.listDisplayMode {
                case .detail:
                    DetailList(
                        galleries: galleries, setting: setting, pageNumber: pageNumber,
                        footerLoadingState: footerLoadingState, fetchMoreAction: fetchMoreAction,
                        navigateAction: navigateAction, translateAction: translateAction
                    )
                case .thumbnail:
                    WaterfallList(
                        galleries: galleries, setting: setting, pageNumber: pageNumber,
                        footerLoadingState: footerLoadingState, fetchMoreAction: fetchMoreAction,
                        navigateAction: navigateAction, translateAction: translateAction
                    )
                }
            }
            .opacity(loadingState == .idle ? 1 : 0).zIndex(2)
            LoadingView().opacity(loadingState == .loading ? 1 : 0).zIndex(0)
            let error = (/LoadingState.failed).extract(from: loadingState)
            ErrorView(error: error ?? .unknown, action: fetchAction)
                .opacity([.idle, .loading].contains(loadingState) ? 0 : 1).zIndex(1)
        }
        .animation(.default, value: loadingState)
        .animation(.default, value: galleries)
        .refreshable { fetchAction?() }
    }
}

// MARK: DetailList
private struct DetailList: View {
    private let galleries: [Gallery]
    private let setting: Setting
    private let pageNumber: PageNumber?
    private let footerLoadingState: LoadingState
    private let fetchMoreAction: (() -> Void)?
    private let navigateAction: ((String) -> Void)?
    private let translateAction: ((String) -> (String, TagTranslation?))?

    init(
        galleries: [Gallery], setting: Setting, pageNumber: PageNumber?,
        footerLoadingState: LoadingState,
        fetchMoreAction: (() -> Void)?,
        navigateAction: ((String) -> Void)? = nil,
        translateAction: ((String) -> (String, TagTranslation?))? = nil
    ) {
        self.galleries = galleries
        self.setting = setting
        self.pageNumber = pageNumber
        self.footerLoadingState = footerLoadingState
        self.fetchMoreAction = fetchMoreAction
        self.navigateAction = navigateAction
        self.translateAction = translateAction
    }

    private func shouldShowFooter(gallery: Gallery) -> Bool {
        guard let pageNumber = pageNumber, fetchMoreAction != nil else { return false }

        let isLastGallery = gallery == galleries.last
        let isPageNumberValid = pageNumber.hasNextPage()
        let isLoadingStateIdle = footerLoadingState == .idle

        return isLastGallery && isPageNumberValid && !isLoadingStateIdle
    }

    var body: some View {
        List(galleries) { gallery in
            Button {
                navigateAction?(gallery.id)
            } label: {
                GalleryDetailCell(gallery: gallery, setting: setting, translateAction: translateAction)
            }
            .foregroundColor(.primary)
            .onAppear {
                if gallery == galleries.last {
                    fetchMoreAction?()
                }
            }
            if shouldShowFooter(gallery: gallery) {
                FetchMoreFooter(loadingState: footerLoadingState, retryAction: fetchMoreAction)
            }
        }
    }
}

// MARK: WaterfallList
private struct WaterfallList: View {
    private let galleries: [Gallery]
    private let setting: Setting
    private let pageNumber: PageNumber?
    private let footerLoadingState: LoadingState
    private let fetchMoreAction: (() -> Void)?
    private let navigateAction: ((String) -> Void)?
    private let translateAction: ((String) -> (String, TagTranslation?))?

    /// Derived from the live container width so that rotation and iPad split view reflow the
    /// masonry, which the previous `WaterfallGrid` handled internally.
    private func columnCount(width: CGFloat) -> Int {
        guard DeviceUtil.isPadWidth else { return 2 }
        return width >= DeviceUtil.windowH ? 5 : 4
    }

    /// A pagination control is only meaningful when the caller can actually load more and
    /// the server reported a next page. Otherwise nothing is rendered, so no dead, VoiceOver
    /// actionable chevron is exposed.
    private var canFetchMore: Bool {
        fetchMoreAction != nil && pageNumber?.hasNextPage() == true
    }

    init(
        galleries: [Gallery], setting: Setting, pageNumber: PageNumber?,
        footerLoadingState: LoadingState,
        fetchMoreAction: (() -> Void)?,
        navigateAction: ((String) -> Void)? = nil,
        translateAction: ((String) -> (String, TagTranslation?))? = nil
    ) {
        self.galleries = galleries
        self.setting = setting
        self.pageNumber = pageNumber
        self.footerLoadingState = footerLoadingState
        self.fetchMoreAction = fetchMoreAction
        self.navigateAction = navigateAction
        self.translateAction = translateAction
    }

    /// Round-robin column assignment keeps the masonry lazy: each column is its own
    /// `LazyVStack`, so paginated cells and their images are only realized while visible
    /// instead of being retained for the whole session inside a single `List` row.
    private func columnGalleries(_ column: Int, columnCount: Int) -> [Gallery] {
        stride(from: column, to: galleries.count, by: columnCount).map { galleries[$0] }
    }

    @ViewBuilder private func cell(gallery: Gallery) -> some View {
        Button {
            navigateAction?(gallery.id)
        } label: {
            GalleryThumbnailCell(gallery: gallery, setting: setting, translateAction: translateAction)
                .tint(.primary).multilineTextAlignment(.leading)
        }
        .buttonStyle(.borderless)
        .onAppear {
            // In-content pagination sentinel.
            if gallery == galleries.last {
                fetchMoreAction?()
            }
        }
    }

    @ViewBuilder private var paginationFooter: some View {
        if canFetchMore, let fetchMoreAction = fetchMoreAction {
            switch footerLoadingState {
            case .idle:
                Button(action: fetchMoreAction) {
                    HStack {
                        Spacer()
                        Image(systemSymbol: .chevronDown)
                        Spacer()
                    }
                }
                .foregroundStyle(.tint)
                .frame(height: 50)
            default:
                FetchMoreFooter(loadingState: footerLoadingState, retryAction: fetchMoreAction)
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = columnCount(width: proxy.size.width)
            ScrollView {
                VStack(spacing: 15) {
                    HStack(alignment: .top, spacing: 15) {
                        ForEach(0..<columns, id: \.self) { column in
                            LazyVStack(spacing: 15) {
                                ForEach(columnGalleries(column, columnCount: columns)) { gallery in
                                    cell(gallery: gallery)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    paginationFooter
                }
                .padding(15)
            }
        }
    }
}
