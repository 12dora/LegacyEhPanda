//
//  FavoritesReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/12/29.
//

import SwiftUI
import IdentifiedCollections
import ComposableArchitecture

struct FavoritesReducer: Reducer {
    enum Route: Equatable {
        case quickSearch
        case detail(String)
    }

    /// Cancellation is scoped per favorites category so that switching categories cannot
    /// strand another category's loading state.
    private enum CancelID: Hashable {
        case fetchGalleries(Int)
        case fetchMoreGalleries(Int)
        case fetchDateSeekGalleries(Int)
    }

    /// Backstop for a run of empty-but-continuable pages, bounding the work even while the
    /// server keeps advancing its cursor.
    private static let maxEmptyPageContinuations = 10

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var keyword = ""
        @BindingState var dateSeekPresented = false
        @BindingState var dateSeekDate = Date()

        var index = -1
        var sortOrder: FavoritesSortOrder?

        var rawGalleries = [Int: [Gallery]]()
        var rawPageNumber = [Int: PageNumber]()
        var rawLoadingState = [Int: LoadingState]()
        var rawFooterLoadingState = [Int: LoadingState]()
        /// Identifies the current base request per category. Footer completions carrying an
        /// older generation are rejected so a replaced page can never append to a newer list.
        var rawRequestGeneration = [Int: Int]()
        /// Continuation cursor per category, held separately from the rendered list so that an
        /// empty page cannot reuse a previous request's last item.
        var rawLastGalleryID = [Int: String]()
        var rawEmptyPageContinuations = [Int: Int]()

        var galleries: [Gallery]? {
            rawGalleries[index]
        }
        var pageNumber: PageNumber? {
            rawPageNumber[index]
        }
        var loadingState: LoadingState? {
            rawLoadingState[index]
        }
        var footerLoadingState: LoadingState? {
            rawFooterLoadingState[index]
        }

        @Heap var detailState: DetailReducer.State!
        var quickSearchState = QuickSearchReducer.State()

        init() {
            _detailState = .init(.init())
        }

        mutating func insertGalleries(index: Int, galleries: [Gallery]) {
            galleries.forEach { gallery in
                if rawGalleries[index]?.contains(gallery) == false {
                    rawGalleries[index]?.append(gallery)
                }
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case setFavoritesIndex(Int)
        case clearSubStates
        case onNotLoginViewButtonTapped

        case fetchGalleries(String? = nil, FavoritesSortOrder? = nil)
        case fetchGalleriesDone(Int, Int, Result<(PageNumber, FavoritesSortOrder?, [Gallery]), AppError>)
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(Int, Int, Result<(PageNumber, FavoritesSortOrder?, [Gallery]), AppError>)
        case presentDateSeek
        case performDateSeek(DateSeekDirection)
        case performDateSeekDone(Int, Int, Result<(PageNumber, [Gallery]), AppError>)

        case detail(DetailReducer.Action)
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

            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return route == nil ? .send(.clearSubStates) : .none

            case .setFavoritesIndex(let index):
                state.index = index
                guard state.galleries?.isEmpty != false else { return .none }
                return .send(.fetchGalleries())

            case .clearSubStates:
                state.detailState = .init(replacing: state.detailState)
                return .send(.detail(.teardown))

            case .onNotLoginViewButtonTapped:
                return .none

            case .fetchGalleries(let keyword, let sortOrder):
                let index = state.index
                if let keyword = keyword {
                    state.keyword = keyword
                }
                // Latest-wins within the category: a new keyword/sort submission replaces the
                // in-flight base request and its footer continuation instead of being dropped.
                let generation = (state.rawRequestGeneration[index] ?? 0) + 1
                state.rawRequestGeneration[index] = generation
                state.rawLastGalleryID[index] = nil
                state.rawEmptyPageContinuations[index] = 0
                state.rawLoadingState[index] = .loading
                state.rawFooterLoadingState[index] = .idle
                if state.rawPageNumber[index] == nil {
                    state.rawPageNumber[index] = PageNumber()
                } else {
                    state.rawPageNumber[index]?.resetPages()
                }
                return .merge(
                    .cancel(id: CancelID.fetchMoreGalleries(index)),
                    .cancel(id: CancelID.fetchDateSeekGalleries(index)),
                    .run { [keyword = state.keyword] send in
                        let response = await FavoritesGalleriesRequest(
                            favIndex: index, keyword: keyword, sortOrder: sortOrder
                        )
                        .response()
                        await send(.fetchGalleriesDone(index, generation, response))
                    }
                    .cancellable(id: CancelID.fetchGalleries(index), cancelInFlight: true)
                )

            case .fetchGalleriesDone(let targetFavIndex, let generation, let result):
                guard generation == state.rawRequestGeneration[targetFavIndex] ?? 0 else { return .none }
                state.rawLoadingState[targetFavIndex] = .idle
                switch result {
                case .success(let (pageNumber, sortOrder, galleries)):
                    // Retain the returned pagination before any continuation is dispatched.
                    state.rawPageNumber[targetFavIndex] = pageNumber
                    guard !galleries.isEmpty else {
                        state.rawLoadingState[targetFavIndex] = .failed(.notFound)
                        // An empty page carries no row to continue from; only the server's own
                        // cursor can advance past it.
                        guard pageNumber.hasNextPage(), targetFavIndex == state.index,
                              pageNumber.nextPageCursor != nil
                        else { return .none }
                        return .send(.fetchMoreGalleries)
                    }
                    state.rawGalleries[targetFavIndex] = galleries
                    state.rawLastGalleryID[targetFavIndex] = galleries.last?.id
                    if targetFavIndex == state.index {
                        state.sortOrder = sortOrder
                    }
                    return .run { _ in
                        let result = await databaseClient.cacheGalleries(galleries)
                        if case .failure(let error) = result {
                            Logger.error("Failed to cache favorite galleries.", context: ["error": "\(error)"])
                        }
                    }
                case .failure(let error):
                    state.rawLoadingState[targetFavIndex] = .failed(error)
                }
                return .none

            case .fetchMoreGalleries:
                let index = state.index
                let pageNumber = state.pageNumber ?? .init()
                let cursor = pageNumber.nextPageCursor
                guard pageNumber.hasNextPage(),
                      state.footerLoadingState != .loading,
                      cursor != nil
                        || (state.rawLastGalleryID[index] != nil && pageNumber.lastItemTimestamp != nil)
                else { return .none }
                state.rawFooterLoadingState[index] = .loading
                let generation = state.rawRequestGeneration[index] ?? 0
                // Fallbacks are only consulted when the listing exposed no cursor.
                let fallbackID = state.rawLastGalleryID[index] ?? ""
                let fallbackTimestamp = pageNumber.lastItemTimestamp ?? ""
                return .run { [keyword = state.keyword] send in
                    let response = await MoreFavoritesGalleriesRequest(
                        favIndex: index,
                        lastID: fallbackID,
                        lastTimestamp: fallbackTimestamp,
                        keyword: keyword,
                        nextCursor: cursor
                    )
                    .response()
                    await send(.fetchMoreGalleriesDone(index, generation, response))
                }
                .cancellable(id: CancelID.fetchMoreGalleries(index), cancelInFlight: true)

            case .fetchMoreGalleriesDone(let targetFavIndex, let generation, let result):
                guard generation == state.rawRequestGeneration[targetFavIndex] ?? 0 else { return .none }
                state.rawFooterLoadingState[targetFavIndex] = .idle
                switch result {
                case .success(let (pageNumber, sortOrder, galleries)):
                    let previousCursor = state.rawPageNumber[targetFavIndex]?.nextPageCursor
                    state.rawPageNumber[targetFavIndex] = pageNumber
                    state.insertGalleries(index: targetFavIndex, galleries: galleries)
                    if targetFavIndex == state.index {
                        state.sortOrder = sortOrder
                    }

                    var effects: [Effect<Action>] = [
                        .run { _ in
                            let result = await databaseClient.cacheGalleries(galleries)
                            if case .failure(let error) = result {
                                Logger.error("Failed to cache favorite galleries.", context: ["error": "\(error)"])
                            }
                        }
                    ]
                    if galleries.isEmpty {
                        let continuations = (state.rawEmptyPageContinuations[targetFavIndex] ?? 0) + 1
                        state.rawEmptyPageContinuations[targetFavIndex] = continuations
                        // Continue only while the server keeps handing back a *new* cursor: an
                        // unchanged cursor would replay the same empty page forever.
                        if pageNumber.hasNextPage(), targetFavIndex == state.index,
                           let cursor = pageNumber.nextPageCursor, cursor != previousCursor,
                           continuations <= Self.maxEmptyPageContinuations {
                            effects.append(.send(.fetchMoreGalleries))
                        }
                    } else {
                        state.rawEmptyPageContinuations[targetFavIndex] = 0
                        state.rawLastGalleryID[targetFavIndex] = galleries.last?.id
                        state.rawLoadingState[targetFavIndex] = .idle
                    }
                    return .merge(effects)

                case .failure(let error):
                    state.rawFooterLoadingState[targetFavIndex] = .failed(error)
                }
                return .none

            case .presentDateSeek:
                guard let navigation = state.pageNumber?.dateSeekNavigation else { return .none }
                state.dateSeekDate = navigation.clampedDate(state.dateSeekDate)
                state.dateSeekPresented = true
                return .run(operation: { _ in hapticsClient.generateFeedback(.light) })

            case .performDateSeek(let direction):
                guard let url = state.pageNumber?.dateSeekNavigation?
                    .seekURL(date: state.dateSeekDate, direction: direction)
                else { return .none }
                let index = state.index
                state.dateSeekPresented = false
                let generation = (state.rawRequestGeneration[index] ?? 0) + 1
                state.rawRequestGeneration[index] = generation
                state.rawLastGalleryID[index] = nil
                state.rawEmptyPageContinuations[index] = 0
                state.rawLoadingState[index] = .loading
                state.rawFooterLoadingState[index] = .idle
                state.rawPageNumber[index]?.resetPages()
                return .merge(
                    .cancel(id: CancelID.fetchGalleries(index)),
                    .cancel(id: CancelID.fetchMoreGalleries(index)),
                    .run { send in
                        await send(
                            .performDateSeekDone(
                                index, generation, await DateSeekGalleriesRequest(url: url).response()
                            )
                        )
                    }
                    .cancellable(id: CancelID.fetchDateSeekGalleries(index), cancelInFlight: true)
                )

            case .performDateSeekDone(let targetFavIndex, let generation, let result):
                guard generation == state.rawRequestGeneration[targetFavIndex] ?? 0 else { return .none }
                state.rawLoadingState[targetFavIndex] = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    state.rawPageNumber[targetFavIndex] = pageNumber
                    guard !galleries.isEmpty else {
                        state.rawLoadingState[targetFavIndex] = .failed(.notFound)
                        return .none
                    }
                    state.rawGalleries[targetFavIndex] = galleries
                    state.rawLastGalleryID[targetFavIndex] = galleries.last?.id
                    if targetFavIndex == state.index,
                       let navigation = pageNumber.dateSeekNavigation {
                        state.dateSeekDate = navigation.clampedDate(state.dateSeekDate)
                    }
                    return .run { _ in
                        let result = await databaseClient.cacheGalleries(galleries)
                        if case .failure(let error) = result {
                            Logger.error("Failed to cache favorite date galleries.", context: ["error": "\(error)"])
                        }
                    }
                case .failure(let error):
                    state.rawLoadingState[targetFavIndex] = .failed(error)
                    return .none
                }

            case .detail:
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

        Scope(state: \.detailState, action: /Action.detail, child: DetailReducer.init)
        Scope(state: \.quickSearchState, action: /Action.quickSearch, child: QuickSearchReducer.init)
    }
}
