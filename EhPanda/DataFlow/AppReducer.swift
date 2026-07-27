//
//  AppReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/12/25.
//

import SwiftUI
import ComposableArchitecture

struct AppReducer: Reducer {
    struct State: Equatable {
        var appDelegateState = AppDelegateReducer.State()
        @BindingState var appRouteState = AppRouteReducer.State()
        var appLockState = AppLockReducer.State()
        var tabBarState = TabBarReducer.State()
        var homeState = HomeReducer.State()
        var favoritesState = FavoritesReducer.State()
        var searchRootState = SearchRootReducer.State()
        @BindingState var settingState = SettingReducer.State()

        /// The phase of every connected scene, keyed by its identity. The app lock reacts to the
        /// aggregate only, so one iPad window going inactive cannot blur or lock the others.
        var scenePhases = [UUID: ScenePhase]()
        /// A custom scheme URL that arrived before the app was able to act on it.
        var pendingDeepLinkURL: URL?

        var aggregateScenePhase: ScenePhase {
            if scenePhases.values.contains(.active) {
                return .active
            } else if scenePhases.values.contains(.inactive) {
                return .inactive
            } else {
                return .background
            }
        }
        /// Deep links may only be consumed once the database and the user settings are available.
        var isReadyForDeepLink: Bool {
            appDelegateState.migrationState.databaseState == .idle && settingState.hasLoadedInitialSetting
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        /// The phase of a single scene. Only the aggregate reaches `onScenePhaseChange`.
        case onSceneChange(UUID, ScenePhase)
        case onSceneDisappear(UUID)
        case onScenePhaseChange(ScenePhase)
        case onOpenURL(URL)
        case openSettings

        case appDelegate(AppDelegateReducer.Action)
        case appRoute(AppRouteReducer.Action)
        case appLock(AppLockReducer.Action)

        case tabBar(TabBarReducer.Action)

        case home(HomeReducer.Action)
        case favorites(FavoritesReducer.Action)
        case searchRoot(SearchRootReducer.Action)
        case setting(SettingReducer.Action)
    }

    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.cookieClient) private var cookieClient
    @Dependency(\.deviceClient) private var deviceClient
    @Dependency(\.databaseClient) private var databaseClient

    var body: some Reducer<State, Action> {
        LoggingReducer {
            BindingReducer()
                .onChange(of: \.appRouteState.route) { _, newValue in
                    Reduce { _, _ in
                        return newValue == nil ? .send(.appRoute(.clearSubStates)) : .none
                    }
                }
                .onChange(of: \.settingState.setting) { _, _ in
                    Reduce { _, _ in
                        return .send(.setting(.syncSetting))
                    }
                }

            Reduce { state, action in
                switch action {
                case .binding:
                    return .none

                case .onSceneChange(let sceneID, let scenePhase):
                    // Several windows share this store, so the app only reacts once all of them
                    // agree: a single iPad window going inactive must not blur or lock the others.
                    let previousPhase = state.aggregateScenePhase
                    state.scenePhases[sceneID] = scenePhase
                    let currentPhase = state.aggregateScenePhase
                    guard currentPhase != previousPhase else { return .none }
                    return .send(.onScenePhaseChange(currentPhase))

                case .onSceneDisappear(let sceneID):
                    let previousPhase = state.aggregateScenePhase
                    state.scenePhases.removeValue(forKey: sceneID)
                    let currentPhase = state.aggregateScenePhase
                    guard currentPhase != previousPhase else { return .none }
                    return .send(.onScenePhaseChange(currentPhase))

                case .onScenePhaseChange(let scenePhase):
                    guard state.settingState.hasLoadedInitialSetting else { return .none }

                    switch scenePhase {
                    case .active:
                        let threshold = state.settingState.setting.autoLockPolicy.rawValue
                        let blurRadius = state.settingState.setting.backgroundBlurRadius
                        return .send(.appLock(.onBecomeActive(threshold, blurRadius)))

                    case .inactive:
                        let blurRadius = state.settingState.setting.backgroundBlurRadius
                        return .merge(
                            .send(.appLock(.onBecomeInactive(blurRadius))),
                            // The debounced settings write is not crash proof. This only runs when
                            // the app as a whole stops being frontmost, so several windows cannot
                            // fight over it.
                            .run { [setting = state.settingState.setting] _ in
                                let result = await databaseClient.updateSetting(setting)
                                if case .failure(let error) = result {
                                    Logger.error("Failed to persist setting on inactive.", context: [
                                        "error": "\(error)"
                                    ])
                                }
                            }
                        )

                    default:
                        return .none
                    }

                case .onOpenURL(let url):
                    // A cold launch reaches this before the tab bar (and the route it needs)
                    // exists, so the intent is queued instead of being dropped.
                    guard state.isReadyForDeepLink else {
                        state.pendingDeepLinkURL = url
                        return .none
                    }
                    return .send(.appRoute(.handleDeepLink(url)))

                case .openSettings:
                    // The Settings tab cannot be selected on iPad, where it is presented as a
                    // sheet instead. Sending the tab action there did nothing at all.
                    if deviceClient.isPad() {
                        return .send(.appRoute(.setNavigation(.setting)))
                    } else {
                        return .send(.tabBar(.setTabBarItemType(.setting)))
                    }

                case .appDelegate(.migration(.onDatabasePreparationSuccess)):
                    return .merge(
                        .send(.appDelegate(.removeExpiredImageURLs)),
                        .send(.setting(.loadUserSettings))
                    )

                case .appDelegate:
                    return .none

                case .appRoute(.clearSubStates):
                    var effects = [Effect<Action>]()
                    if deviceClient.isPad() {
                        state.settingState.route = nil
                        effects.append(.send(.setting(.clearSubStates)))
                    }
                    return effects.isEmpty ? .none : .merge(effects)

                case .appRoute:
                    return .none

                case .appLock(.unlockApp):
                    var effects: [Effect<Action>] = [
                        .send(.setting(.fetchGreeting))
                    ]
                    if state.settingState.setting.detectsLinksFromClipboard {
                        effects.append(.send(.appRoute(.detectClipboardURL)))
                    }
                    return .merge(effects)

                case .appLock:
                    return .none

                case .tabBar(.setTabBarItemType(let type)):
                    var effects = [Effect<Action>]()
                    let hapticEffect: Effect<Action> = .run(operation: { _ in hapticsClient.generateFeedback(.soft) })
                    if type == state.tabBarState.tabBarItemType {
                        switch type {
                        case .home:
                            if state.homeState.route != nil {
                                effects.append(.send(.home(.setNavigation(nil))))
                            } else {
                                effects.append(.send(.home(.fetchAllGalleries)))
                            }
                        case .favorites:
                            if state.favoritesState.route != nil {
                                effects.append(.send(.favorites(.setNavigation(nil))))
                                effects.append(hapticEffect)
                            } else if cookieClient.didLogin {
                                effects.append(.send(.favorites(.fetchGalleries())))
                                effects.append(hapticEffect)
                            }
                        case .search:
                            if state.searchRootState.route != nil {
                                effects.append(.send(.searchRoot(.setNavigation(nil))))
                            } else {
                                effects.append(.send(.searchRoot(.fetchDatabaseInfos)))
                            }
                        case .downloads:
                            break
                        case .setting:
                            if state.settingState.route != nil {
                                effects.append(.send(.setting(.setNavigation(nil))))
                                effects.append(hapticEffect)
                            }
                        }
                        if [.home, .search].contains(type) {
                            effects.append(hapticEffect)
                        }
                    }
                    return effects.isEmpty ? .none : .merge(effects)

                case .tabBar:
                    return .none

                case .home(.watched(.onNotLoginViewButtonTapped)), .favorites(.onNotLoginViewButtonTapped):
                    var effects: [Effect<Action>] = [
                        .run(operation: { _ in hapticsClient.generateFeedback(.soft) }),
                        .send(.openSettings)
                    ]
                    effects.append(.send(.setting(.setNavigation(.account))))
                    if !cookieClient.didLogin {
                        effects.append(
                            .run { send in
                                let delay = UInt64(deviceClient.isPad() ? 1200 : 200)
                                try await Task.sleep(for: .milliseconds(delay))
                                await send(.setting(.account(.setNavigation(.login))))
                            }
                        )
                    }
                    return .merge(effects)

                case .home:
                    return .none

                case .favorites:
                    return .none

                case .searchRoot:
                    return .none

                case .setting(.loadUserSettingsDone):
                    var effects = [Effect<Action>]()
                    let threshold = state.settingState.setting.autoLockPolicy.rawValue
                    let blurRadius = state.settingState.setting.backgroundBlurRadius
                    if threshold >= 0 {
                        state.appLockState.becameInactiveDate = .distantPast
                        effects.append(.send(.appLock(.onBecomeActive(threshold, blurRadius))))
                    }
                    if state.settingState.setting.detectsLinksFromClipboard {
                        effects.append(.send(.appRoute(.detectClipboardURL)))
                    }
                    // The app is ready now, so a URL that launched it can finally be handled. It
                    // goes last, so that it wins over a clipboard link detected at the same time.
                    if let url = state.pendingDeepLinkURL {
                        state.pendingDeepLinkURL = nil
                        effects.append(.send(.appRoute(.handleDeepLink(url))))
                    }
                    return effects.isEmpty ? .none : .merge(effects)

                case .setting(.fetchGreetingDone(let result)):
                    return .send(.appRoute(.fetchGreetingDone(result)))

                case .setting:
                    return .none
                }
            }

            Scope(state: \.appRouteState, action: /Action.appRoute, child: AppRouteReducer.init)
            Scope(state: \.appLockState, action: /Action.appLock, child: AppLockReducer.init)
            Scope(state: \.appDelegateState, action: /Action.appDelegate, child: AppDelegateReducer.init)
            Scope(state: \.tabBarState, action: /Action.tabBar, child: TabBarReducer.init)
            Scope(state: \.homeState, action: /Action.home, child: HomeReducer.init)
            Scope(state: \.favoritesState, action: /Action.favorites, child: FavoritesReducer.init)
            Scope(state: \.searchRootState, action: /Action.searchRoot, child: SearchRootReducer.init)
            Scope(state: \.settingState, action: /Action.setting, child: SettingReducer.init)
        }
    }
}
