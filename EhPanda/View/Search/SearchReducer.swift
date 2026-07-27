//
//  SearchReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/12.
//

import ComposableArchitecture

struct SearchReducer: Reducer {
    enum Route: Equatable {
        case filters
        case quickSearch
        case detail(String)
    }

    private enum CancelID: CaseIterable {
        case fetchGalleries, fetchMoreGalleries
    }

    /// Backstop for a run of empty-but-continuable pages, bounding the work even while the
    /// server keeps advancing its cursor.
    private static let maxEmptyPageContinuations = 10

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var keyword = ""
        var lastKeyword = ""

        var galleries = [Gallery]()
        var pageNumber = PageNumber()
        var loadingState: LoadingState = .idle
        var footerLoadingState: LoadingState = .idle

        /// Identifies the current base request. Footer completions carrying an older
        /// generation are rejected so that a previous query can never append to a newer list.
        var requestGeneration = 0
        /// Continuation cursor, held separately from the rendered list so that an empty page
        /// cannot reuse a previous request's last item.
        var lastGalleryID: String?
        var emptyPageContinuations = 0

        var filtersState = FiltersReducer.State()
        @Heap var detailState: DetailReducer.State!
        var quickSearchState = QuickSearchReducer.State()

        init() {
            _detailState = .init(.init())
        }

        mutating func insertGalleries(_ galleries: [Gallery]) {
            galleries.forEach { gallery in
                if !self.galleries.contains(gallery) {
                    self.galleries.append(gallery)
                }
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates

        case teardown
        case fetchGalleries(String? = nil)
        case fetchGalleriesDone(Int, Result<(PageNumber, [Gallery]), AppError>)
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(Int, Result<(PageNumber, [Gallery]), AppError>)

        case detail(DetailReducer.Action)
        case filters(FiltersReducer.Action)
        case quickSearch(QuickSearchReducer.Action)
    }

    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.hapticsClient) private var hapticsClient

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding(\.$route):
                return state.route == nil ? .send(.clearSubStates) : .none

            case .binding(\.$keyword):
                if !state.keyword.isEmpty {
                    state.lastKeyword = state.keyword
                }
                return .none

            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return route == nil ? .send(.clearSubStates) : .none

            case .clearSubStates:
                state.detailState = .init(replacing: state.detailState)
                state.filtersState = .init()
                state.quickSearchState = .init()
                return .merge(
                    .send(.detail(.teardown)),
                    .send(.quickSearch(.teardown))
                )

            case .teardown:
                return .merge(CancelID.allCases.map(Effect.cancel(id:)))

            case .fetchGalleries(let keyword):
                if let keyword = keyword {
                    state.keyword = keyword
                    state.lastKeyword = keyword
                }
                // Latest-wins: a new submission replaces the in-flight base request and any
                // footer continuation instead of being dropped while an old result appends.
                state.requestGeneration += 1
                state.lastGalleryID = nil
                state.emptyPageContinuations = 0
                state.loadingState = .loading
                state.footerLoadingState = .idle
                state.pageNumber.resetPages()
                let generation = state.requestGeneration
                let filter = databaseClient.fetchFilterSynchronously(range: .search)
                return .merge(
                    .cancel(id: CancelID.fetchMoreGalleries),
                    .run { [lastKeyword = state.lastKeyword] send in
                        let response = await SearchGalleriesRequest(
                            keyword: lastKeyword, filter: filter
                        )
                        .response()
                        await send(.fetchGalleriesDone(generation, response))
                    }
                    .cancellable(id: CancelID.fetchGalleries, cancelInFlight: true)
                )

            case .fetchGalleriesDone(let generation, let result):
                guard generation == state.requestGeneration else { return .none }
                state.loadingState = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    // Retain the returned pagination before any continuation is dispatched.
                    state.pageNumber = pageNumber
                    guard !galleries.isEmpty else {
                        state.loadingState = .failed(.notFound)
                        // An empty page carries no row to continue from; only the server's own
                        // cursor can advance past it.
                        guard pageNumber.hasNextPage(), pageNumber.nextPageCursor != nil
                        else { return .none }
                        return .send(.fetchMoreGalleries)
                    }
                    state.galleries = galleries
                    state.lastGalleryID = galleries.last?.id
                    return .run { _ in
                        let result = await databaseClient.cacheGalleries(galleries)
                        if case .failure(let error) = result {
                            Logger.error("Failed to cache search galleries.", context: ["error": "\(error)"])
                        }
                    }
                case .failure(let error):
                    state.loadingState = .failed(error)
                }
                return .none

            case .fetchMoreGalleries:
                let pageNumber = state.pageNumber
                let cursor = pageNumber.nextPageCursor
                guard pageNumber.hasNextPage(),
                      state.footerLoadingState != .loading,
                      let lastID = cursor ?? state.lastGalleryID
                else { return .none }
                state.footerLoadingState = .loading
                let generation = state.requestGeneration
                let filter = databaseClient.fetchFilterSynchronously(range: .search)
                return .run { [lastKeyword = state.lastKeyword] send in
                    let response = await MoreSearchGalleriesRequest(
                        keyword: lastKeyword, filter: filter, lastID: lastID, nextCursor: cursor
                    )
                    .response()
                    await send(.fetchMoreGalleriesDone(generation, response))
                }
                .cancellable(id: CancelID.fetchMoreGalleries, cancelInFlight: true)

            case .fetchMoreGalleriesDone(let generation, let result):
                guard generation == state.requestGeneration else { return .none }
                state.footerLoadingState = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    let previousCursor = state.pageNumber.nextPageCursor
                    state.pageNumber = pageNumber
                    state.insertGalleries(galleries)

                    var effects: [Effect<Action>] = [
                        .run { _ in
                            let result = await databaseClient.cacheGalleries(galleries)
                            if case .failure(let error) = result {
                                Logger.error("Failed to cache search galleries.", context: ["error": "\(error)"])
                            }
                        }
                    ]
                    if galleries.isEmpty {
                        state.emptyPageContinuations += 1
                        // Continue only while the server keeps handing back a *new* cursor: an
                        // unchanged cursor would replay the same empty page forever.
                        if pageNumber.hasNextPage(),
                           let cursor = pageNumber.nextPageCursor, cursor != previousCursor,
                           state.emptyPageContinuations <= Self.maxEmptyPageContinuations {
                            effects.append(.send(.fetchMoreGalleries))
                        }
                    } else {
                        state.emptyPageContinuations = 0
                        state.lastGalleryID = galleries.last?.id
                        state.loadingState = .idle
                    }
                    return .merge(effects)

                case .failure(let error):
                    state.footerLoadingState = .failed(error)
                }
                return .none

            case .detail:
                return .none

            case .filters:
                return .none

            case .quickSearch:
                return .none
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.quickSearch,
            hapticsClient: hapticsClient
        )
        .haptics(
            unwrapping: \.route,
            case: /Route.filters,
            hapticsClient: hapticsClient
        )

        Scope(state: \.filtersState, action: /Action.filters, child: FiltersReducer.init)
        Scope(state: \.quickSearchState, action: /Action.quickSearch, child: QuickSearchReducer.init)
        Scope(state: \.detailState, action: /Action.detail, child: DetailReducer.init)
    }
}
