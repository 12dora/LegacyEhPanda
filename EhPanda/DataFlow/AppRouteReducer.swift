//
//  AppRouteReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/08.
//

import SwiftUI
import ComposableArchitecture

struct AppRouteReducer: Reducer {
    enum Route: Equatable, Hashable {
        case hud
        case setting
        case detail(String)
        case newDawn(Greeting)
    }

    struct State: Equatable {
        @BindingState var route: Route?
        var hudConfig: AppToastConfig = .loading

        /// Identifies the deep link that is currently being resolved. Every completion carries the
        /// generation it belongs to, so a superseded one can never write navigation any more.
        var deepLinkGeneration = 0
        /// A greeting that arrived while the user was busy, waiting for the app to become idle.
        var pendingGreeting: Greeting?
        /// The greeting that has already been shown, so repeated responses do not present twice.
        var presentedGreeting: Greeting?

        @Heap var detailState: DetailReducer.State!

        init() {
            _detailState = .init(.init())
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case setHUDConfig(AppToastConfig)
        case clearSubStates

        case detectClipboardURL
        case handleDeepLink(URL)
        case handleGalleryLink(URL, Int)

        case updateReadingProgress(String, Int)

        case fetchGallery(URL, Bool, Int)
        case fetchGalleryDone(URL, Result<Gallery, AppError>, Int)
        case fetchGreetingDone(Result<Greeting, AppError>)
        case presentPendingGreeting

        case detail(DetailReducer.Action)
    }

    private enum CancelID {
        case deepLink
    }

    @Dependency(\.userDefaultsClient) private var userDefaultsClient
    @Dependency(\.clipboardClient) private var clipboardClient
    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.urlClient) private var urlClient

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

            case .setHUDConfig(let config):
                state.hudConfig = config
                return .none

            case .clearSubStates:
                state.detailState = .init(replacing: state.detailState)
                var effects: [Effect<Action>] = [.send(.detail(.teardown))]
                if state.pendingGreeting != nil {
                    effects.append(
                        .run { send in
                            // Let the dismissal of the user's own screen finish first.
                            try await Task.sleep(for: .milliseconds(500))
                            await send(.presentPendingGreeting)
                        }
                    )
                }
                return .merge(effects)

            case .detectClipboardURL:
                let currentChangeCount = clipboardClient.changeCount()
                guard currentChangeCount != userDefaultsClient
                        .getValue(.clipboardChangeCount) else { return .none }
                var effects: [Effect<Action>] = [
                    .run(operation: { _ in userDefaultsClient.setValue(currentChangeCount, .clipboardChangeCount) })
                ]
                if let url = clipboardClient.url() {
                    effects.append(.send(.handleDeepLink(url)))
                }
                return .merge(effects)

            case .handleDeepLink(let url):
                let url = urlClient.resolveAppSchemeURL(url) ?? url
                guard urlClient.checkIfHandleable(url) else { return .none }
                // A newer intent owns navigation from here on: every effect below is keyed to this
                // generation and cancels the effects of the intent it replaces.
                state.deepLinkGeneration &+= 1
                let generation = state.deepLinkGeneration
                var delay = 0
                var effects = [Effect<Action>]()
                if case .detail = state.route {
                    delay = 1000
                    state.route = nil
                    // The replaced detail has to be torn down, or its requests keep running. Its
                    // cancellation identities are carried over, or the teardown below would
                    // target the replacement instead of the instance that started them.
                    state.detailState = .init(replacing: state.detailState)
                    effects.append(.send(.detail(.teardown)))
                }
                let (isGalleryImageURL, _, _) = urlClient.analyzeURL(url)
                let gid = urlClient.parseGalleryID(url)
                guard databaseClient.fetchGallery(gid: gid) == nil else {
                    effects.append(
                        .run { [delay] send in
                            try await Task.sleep(for: .milliseconds(delay + 250))
                            await send(.handleGalleryLink(url, generation))
                        }
                        .cancellable(id: CancelID.deepLink, cancelInFlight: true)
                    )
                    return .merge(effects)
                }
                effects.append(
                    .run { [delay] send in
                        try await Task.sleep(for: .milliseconds(delay))
                        await send(.fetchGallery(url, isGalleryImageURL, generation))
                    }
                    .cancellable(id: CancelID.deepLink, cancelInFlight: true)
                )
                return .merge(effects)

            case .handleGalleryLink(let url, let generation):
                guard generation == state.deepLinkGeneration else { return .none }
                let (_, pageIndex, commentID) = urlClient.analyzeURL(url)
                let gid = urlClient.parseGalleryID(url)
                var effects = [Effect<Action>]()
                state.detailState = .init(replacing: state.detailState)
                effects.append(.send(.detail(.teardown)))
                effects.append(.send(.detail(.fetchDatabaseInfos(gid))))
                if let pageIndex = pageIndex {
                    effects.append(.send(.updateReadingProgress(gid, pageIndex)))
                    effects.append(
                        .run { send in
                            try await Task.sleep(for: .milliseconds(500))
                            await send(.detail(.setNavigation(.reading)))
                        }
                        .cancellable(id: CancelID.deepLink)
                    )
                } else if let commentID = commentID {
                    state.detailState.commentsState?.scrollCommentID = commentID
                    effects.append(
                        .run { send in
                            try await Task.sleep(for: .milliseconds(500))
                            await send(.detail(.setNavigation(.comments(url))))
                        }
                        .cancellable(id: CancelID.deepLink)
                    )
                }
                effects.append(.send(.setNavigation(.detail(gid))))
                return .merge(effects)

            case .updateReadingProgress(let gid, let progress):
                guard !gid.isEmpty else { return .none }
                return .run { _ in
                    let result = await databaseClient.updateReadingProgress(gid: gid, progress: progress)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist deep-link reading progress.", context: [
                            "gid": gid, "progress": progress, "error": "\(error)"
                        ])
                    }
                }

            case .fetchGallery(let url, let isGalleryImageURL, let generation):
                guard generation == state.deepLinkGeneration else { return .none }
                state.route = .hud
                return .run { send in
                    let response = await GalleryReverseRequest(
                        url: url, isGalleryImageURL: isGalleryImageURL
                    )
                    .response()
                    await send(.fetchGalleryDone(url, response, generation))
                }
                .cancellable(id: CancelID.deepLink)

            case .fetchGalleryDone(let url, let result, let generation):
                // A superseded lookup must not clear the route the current intent just opened.
                guard generation == state.deepLinkGeneration else { return .none }
                state.route = nil
                switch result {
                case .success(let gallery):
                    return .run { send in
                        let result = await databaseClient.cacheGalleries([gallery])
                        switch result {
                        case .success:
                            await send(.handleGalleryLink(url, generation))
                        case .failure(let error):
                            Logger.error("Failed to cache reverse lookup gallery.", context: [
                                "gid": gallery.id, "error": "\(error)"
                            ])
                            await send(.setHUDConfig(.error))
                            await send(.setNavigation(.hud))
                        }
                    }
                    .cancellable(id: CancelID.deepLink)
                case .failure:
                    return .run { send in
                        try await Task.sleep(for: .milliseconds(500))
                        await send(.setHUDConfig(.error))
                        await send(.setNavigation(.hud))
                    }
                    .cancellable(id: CancelID.deepLink)
                }

            case .fetchGreetingDone(let result):
                guard case .success(let greeting) = result, !greeting.gainedNothing,
                      greeting != state.presentedGreeting, greeting != state.pendingGreeting
                else { return .none }
                // The greeting never replaces a screen the user opened; it waits for the app
                // to become idle instead.
                guard state.route == nil else {
                    state.pendingGreeting = greeting
                    return .none
                }
                state.presentedGreeting = greeting
                return .send(.setNavigation(.newDawn(greeting)))

            case .presentPendingGreeting:
                guard state.route == nil, let greeting = state.pendingGreeting else { return .none }
                state.pendingGreeting = nil
                state.presentedGreeting = greeting
                return .send(.setNavigation(.newDawn(greeting)))

            case .detail:
                return .none
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.newDawn,
            hapticsClient: hapticsClient
        )
        .haptics(
            unwrapping: \.route,
            case: /Route.detail,
            hapticsClient: hapticsClient
        )

        Scope(state: \.detailState, action: /Action.detail, child: DetailReducer.init)
    }
}
