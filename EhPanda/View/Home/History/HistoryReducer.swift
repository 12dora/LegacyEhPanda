//
//  HistoryReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/09.
//

import Foundation
import ComposableArchitecture

struct HistoryReducer: Reducer {
    enum Route: Equatable {
        case detail(String)
        case clearHistory
    }

    private enum CancelID {
        case fetchGalleries, fetchMoreGalleries, filterKeyword, clearHistory
    }

    /// Page size for the paged, store-side history fetch.
    private static let pageSize = 100

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var keyword = ""
        @BindingState var clearDialogPresented = false

        var galleries = [Gallery]()
        var loadingState: LoadingState = .idle
        var footerLoadingState: LoadingState = .idle
        /// Whether the store reported a full page and may hold more rows.
        var hasMoreGalleries = false

        /// Identifies the current base fetch so that a superseded keyword's rows are ignored.
        var requestGeneration = 0
        /// Non-reusable instance boundary for long-running clear completions.
        var instanceID = UUID()
        /// Clear-history has its own identity so ordinary fetches cannot supersede it.
        var clearGeneration = UUID()
        var isClearingHistory = false

        @Heap var detailState: DetailReducer.State!

        init() {
            _detailState = .init(.init())
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates
        case clearHistoryGalleries
        case clearHistoryGalleriesDone(UUID, UUID, Result<Void, AppError>)

        case teardown
        case fetchGalleries
        case fetchGalleriesDone(Int, [Gallery])
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(Int, [Gallery])

        case detail(DetailReducer.Action)
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
                // Filtering happens in the store, so a keyword change is a debounced refetch
                // rather than a walk over a fully materialized array.
                return .run { send in
                    try await Task.sleep(for: .milliseconds(300))
                    await send(.fetchGalleries)
                }
                .cancellable(id: CancelID.filterKeyword, cancelInFlight: true)

            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return route == nil ? .send(.clearSubStates) : .none

            case .clearSubStates:
                state.detailState = .init(replacing: state.detailState)
                return .send(.detail(.teardown))

            case .clearHistoryGalleries:
                state.clearGeneration = UUID()
                let instanceID = state.instanceID
                let clearGeneration = state.clearGeneration
                state.isClearingHistory = true
                state.loadingState = .loading
                state.footerLoadingState = .idle
                return .merge(
                    .cancel(id: CancelID.filterKeyword),
                    .cancel(id: CancelID.fetchGalleries),
                    .cancel(id: CancelID.fetchMoreGalleries),
                    .run { send in
                        let result = await databaseClient.clearHistoryGalleries()
                        try Task.checkCancellation()
                        await send(.clearHistoryGalleriesDone(instanceID, clearGeneration, result))
                    }
                    .cancellable(id: CancelID.clearHistory, cancelInFlight: true)
                )

            case .clearHistoryGalleriesDone(let instanceID, let clearGeneration, let result):
                guard instanceID == state.instanceID,
                      clearGeneration == state.clearGeneration
                else { return .none }
                switch result {
                case .success:
                    state.isClearingHistory = false
                    state.galleries = []
                    state.hasMoreGalleries = false
                    state.footerLoadingState = .idle
                    return .send(.fetchGalleries)
                case .failure(let error):
                    state.isClearingHistory = false
                    Logger.error("Failed to clear history galleries.", context: ["error": "\(error)"])
                    state.loadingState = .failed(error)
                    return .none
                }

            case .teardown:
                state.requestGeneration += 1
                state.clearGeneration = UUID()
                state.instanceID = UUID()
                state.isClearingHistory = false
                return .merge(
                    .cancel(id: CancelID.clearHistory),
                    .cancel(id: CancelID.fetchGalleries),
                    .cancel(id: CancelID.fetchMoreGalleries),
                    .cancel(id: CancelID.filterKeyword)
                )

            case .fetchGalleries:
                guard !state.isClearingHistory else { return .none }
                state.requestGeneration += 1
                state.loadingState = .loading
                state.footerLoadingState = .idle
                let generation = state.requestGeneration
                let pageSize = Self.pageSize
                return .merge(
                    .cancel(id: CancelID.fetchMoreGalleries),
                    .run { [keyword = state.keyword] send in
                        let historyGalleries = await databaseClient.fetchHistoryGalleries(
                            fetchLimit: pageSize, keyword: keyword
                        )
                        await send(.fetchGalleriesDone(generation, historyGalleries))
                    }
                    .cancellable(id: CancelID.fetchGalleries, cancelInFlight: true)
                )

            case .fetchGalleriesDone(let generation, let galleries):
                guard generation == state.requestGeneration else { return .none }
                state.loadingState = .idle
                state.galleries = galleries
                state.hasMoreGalleries = galleries.count >= Self.pageSize
                if galleries.isEmpty {
                    state.loadingState = .failed(.notFound)
                }
                return .none

            case .fetchMoreGalleries:
                guard state.hasMoreGalleries,
                      state.loadingState != .loading,
                      state.footerLoadingState != .loading
                else { return .none }
                state.footerLoadingState = .loading
                let generation = state.requestGeneration
                let pageSize = Self.pageSize
                let offset = state.galleries.count
                return .run { [keyword = state.keyword] send in
                    let historyGalleries = await databaseClient.fetchHistoryGalleries(
                        fetchLimit: pageSize, fetchOffset: offset, keyword: keyword
                    )
                    await send(.fetchMoreGalleriesDone(generation, historyGalleries))
                }
                .cancellable(id: CancelID.fetchMoreGalleries, cancelInFlight: true)

            case .fetchMoreGalleriesDone(let generation, let galleries):
                guard generation == state.requestGeneration else { return .none }
                state.footerLoadingState = .idle
                state.hasMoreGalleries = galleries.count >= Self.pageSize
                galleries.forEach { gallery in
                    if !state.galleries.contains(gallery) {
                        state.galleries.append(gallery)
                    }
                }
                return .none

            case .detail:
                return .none
            }
        }

        Scope(state: \.detailState, action: /Action.detail, child: DetailReducer.init)
    }
}
