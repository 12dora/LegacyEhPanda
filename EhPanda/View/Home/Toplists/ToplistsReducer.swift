//
//  ToplistsReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/08.
//

import ComposableArchitecture

struct ToplistsReducer: Reducer {
    enum Route: Equatable {
        case detail(String)
    }

    /// Cancellation is scoped per category so that switching categories cannot strand another
    /// category's loading state.
    private enum CancelID: Hashable {
        case fetchGalleries(ToplistsType)
        case fetchMoreGalleries(ToplistsType)

        static var allCases: [CancelID] {
            ToplistsType.allCases.flatMap { [CancelID.fetchGalleries($0), .fetchMoreGalleries($0)] }
        }
    }

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var keyword = ""
        @BindingState var jumpPageIndex = ""
        @BindingState var jumpPageAlertFocused = false
        @BindingState var jumpPageAlertPresented = false

        var type: ToplistsType = .yesterday

        var filteredGalleries: [Gallery]? {
            guard !keyword.isEmpty else { return galleries }
            return galleries?.filter({ $0.title.caseInsensitiveContains(keyword) })
        }

        var rawGalleries = [ToplistsType: [Gallery]]()
        var rawPageNumber = [ToplistsType: PageNumber]()
        var rawLoadingState = [ToplistsType: LoadingState]()
        var rawFooterLoadingState = [ToplistsType: LoadingState]()
        /// Identifies the current base request per category. Footer completions carrying an
        /// older generation are rejected so a replaced page can never append to a newer list.
        var rawRequestGeneration = [ToplistsType: Int]()

        var galleries: [Gallery]? {
            rawGalleries[type]
        }
        var pageNumber: PageNumber? {
            rawPageNumber[type]
        }
        var loadingState: LoadingState? {
            rawLoadingState[type]
        }
        var footerLoadingState: LoadingState? {
            rawFooterLoadingState[type]
        }

        @Heap var detailState: DetailReducer.State!

        init() {
            _detailState = .init(.init())
        }

        mutating func insertGalleries(type: ToplistsType, galleries: [Gallery]) {
            galleries.forEach { gallery in
                if rawGalleries[type]?.contains(gallery) == false {
                    rawGalleries[type]?.append(gallery)
                }
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case setToplistsType(ToplistsType)
        case clearSubStates

        case performJumpPage
        case presentJumpPageAlert
        case setJumpPageAlertFocused(Bool)

        case teardown
        case fetchGalleries(Int? = nil)
        case fetchGalleriesDone(ToplistsType, Int, Result<(PageNumber, [Gallery]), AppError>)
        case fetchMoreGalleries
        case fetchMoreGalleriesDone(ToplistsType, Int, Result<(PageNumber, [Gallery]), AppError>)

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

            case .binding(\.$jumpPageAlertPresented):
                if !state.jumpPageAlertPresented {
                    state.jumpPageAlertFocused = false
                }
                return .none

            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return route == nil ? .send(.clearSubStates) : .none

            case .setToplistsType(let type):
                state.type = type
                guard state.galleries?.isEmpty != false else { return .none }
                return .send(.fetchGalleries())

            case .clearSubStates:
                state.detailState = .init(replacing: state.detailState)
                return .send(.detail(.teardown))

            case .performJumpPage:
                guard let index = Int(state.jumpPageIndex),
                      let pageNumber = state.pageNumber,
                      index > 0, index <= pageNumber.maximum + 1 else {
                    return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })
                }
                return .send(.fetchGalleries(index - 1))

            case .presentJumpPageAlert:
                state.jumpPageAlertPresented = true
                return .run(operation: { _ in hapticsClient.generateFeedback(.light) })

            case .setJumpPageAlertFocused(let isFocused):
                state.jumpPageAlertFocused = isFocused
                return .none

            case .teardown:
                return .merge(CancelID.allCases.map(Effect.cancel(id:)))

            case .fetchGalleries(let pageNum):
                let type = state.type
                // Latest-wins within the category: a jump-page or reload replaces the in-flight
                // base request and its footer continuation instead of being dropped.
                let generation = (state.rawRequestGeneration[type] ?? 0) + 1
                state.rawRequestGeneration[type] = generation
                state.rawLoadingState[type] = .loading
                state.rawFooterLoadingState[type] = .idle
                if state.rawPageNumber[type] == nil {
                    state.rawPageNumber[type] = PageNumber()
                } else {
                    state.rawPageNumber[type]?.resetPages()
                }
                return .merge(
                    .cancel(id: CancelID.fetchMoreGalleries(type)),
                    .run { send in
                        let response = await ToplistsGalleriesRequest(
                            catIndex: type.categoryIndex, pageNum: pageNum
                        )
                        .response()
                        await send(.fetchGalleriesDone(type, generation, response))
                    }
                    .cancellable(id: CancelID.fetchGalleries(type), cancelInFlight: true)
                )

            case .fetchGalleriesDone(let type, let generation, let result):
                guard generation == state.rawRequestGeneration[type] ?? 0 else { return .none }
                state.rawLoadingState[type] = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    state.rawPageNumber[type] = pageNumber
                    guard !galleries.isEmpty else {
                        state.rawGalleries[type] = []
                        state.rawLoadingState[type] = .failed(.notFound)
                        guard pageNumber.hasNextPage(), type == state.type else { return .none }
                        return .send(.fetchMoreGalleries)
                    }
                    state.rawGalleries[type] = galleries
                    return .run { _ in
                        let result = await databaseClient.cacheGalleries(galleries)
                        if case .failure(let error) = result {
                            Logger.error("Failed to cache toplists galleries.", context: ["error": "\(error)"])
                        }
                    }
                case .failure(let error):
                    state.rawLoadingState[type] = .failed(error)
                }
                return .none

            case .fetchMoreGalleries:
                let type = state.type
                let pageNumber = state.pageNumber ?? .init()
                guard pageNumber.hasNextPage(),
                      state.footerLoadingState != .loading
                else { return .none }
                state.rawFooterLoadingState[type] = .loading
                let generation = state.rawRequestGeneration[type] ?? 0
                let pageNum = pageNumber.current + 1
                return .run { send in
                    let response = await MoreToplistsGalleriesRequest(
                        catIndex: type.categoryIndex, pageNum: pageNum
                    )
                    .response()
                    await send(.fetchMoreGalleriesDone(type, generation, response))
                }
                .cancellable(id: CancelID.fetchMoreGalleries(type), cancelInFlight: true)

            case .fetchMoreGalleriesDone(let type, let generation, let result):
                guard generation == state.rawRequestGeneration[type] ?? 0 else { return .none }
                state.rawFooterLoadingState[type] = .idle
                switch result {
                case .success(let (pageNumber, galleries)):
                    state.rawPageNumber[type] = pageNumber
                    state.insertGalleries(type: type, galleries: galleries)

                    var effects: [Effect<Action>] = [
                        .run { _ in
                            let result = await databaseClient.cacheGalleries(galleries)
                            if case .failure(let error) = result {
                                Logger.error("Failed to cache toplists galleries.", context: ["error": "\(error)"])
                            }
                        }
                    ]
                    if galleries.isEmpty, pageNumber.hasNextPage(), type == state.type {
                        effects.append(.send(.fetchMoreGalleries))
                    } else if !galleries.isEmpty {
                        state.rawLoadingState[type] = .idle
                    }
                    return .merge(effects)

                case .failure(let error):
                    state.rawFooterLoadingState[type] = .failed(error)
                }
                return .none

            case .detail:
                return .none
            }
        }

        Scope(state: \.detailState, action: /Action.detail, child: DetailReducer.init)
    }
}
