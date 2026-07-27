//
//  SettingReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/12/31.
//

import Foundation
import ComposableArchitecture

struct SettingReducer: Reducer {
    private enum CancelID: Hashable {
        // Every effect that reads or writes account-scoped data runs under this identifier
        // so a login, a logout or an account replacement can tear all of them down at once.
        case accountSession
        case syncSetting
        case tagTranslatorRequest
    }

    // Settings changes arrive in bursts: the generic binding reducer and the per-field
    // `onChange` reducers both request a sync, and continuous controls emit one per sample.
    // Coalescing them into a single trailing write keeps one ordered persistence path.
    private static let settingSyncDelay: Duration = .milliseconds(200)

    enum Route: Int, Equatable, Hashable, Identifiable, CaseIterable {
        var id: Int { rawValue }

        case account
        case general
        case appearance
        case reading
        case laboratory
        case about
    }

    struct State: Equatable {
        // AppEnvStorage
        @BindingState var setting = Setting()
        var tagTranslator = TagTranslator()
        var user = User()

        var hasLoadedInitialSetting = false
        // Identifies the account session that account-bound effects belong to. Login,
        // logout and account replacement advance it, and completions carrying a stale
        // generation are dropped instead of writing another account's data into state.
        var accountSessionGeneration = 0
        var tagTranslatorGeneration = 0

        @BindingState var route: Route?
        var tagTranslatorLoadingState: LoadingState = .idle

        var accountSettingState = AccountSettingReducer.State()
        var generalSettingState = GeneralSettingReducer.State()
        var appearanceSettingState = AppearanceSettingReducer.State()

        mutating func setGreeting(_ greeting: Greeting) {
            guard let currDate = greeting.updateTime else { return }

            if let prevGreeting = user.greeting,
               let prevDate = prevGreeting.updateTime,
               prevDate < currDate
            {
                user.greeting = greeting
            } else if user.greeting == nil {
                user.greeting = greeting
            }
        }

        mutating func updateUser(_ user: User) {
            if let displayName = user.displayName {
                self.user.displayName = displayName
            }
            if let avatarURL = user.avatarURL {
                self.user.avatarURL = avatarURL
            }
            if let galleryPoints = user.galleryPoints,
               let credits = user.credits
            {
                self.user.galleryPoints = galleryPoints
                self.user.credits = credits
            }
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates

        case syncAppIconType
        case syncUserInterfaceStyle
        case syncSetting
        case syncTagTranslator
        case syncUser(Int)

        case loadUserSettings
        case onLoadUserSettings(AppEnv)
        case loadUserSettingsDone
        case createDefaultEhProfile
        // The leading `Int` on every account-bound response is the session generation the
        // request was issued under; a response whose generation no longer matches is
        // discarded rather than applied to whatever account is signed in now.
        case fetchIgneous
        case fetchIgneousDone(Int, Result<HTTPURLResponse, AppError>)
        case fetchUserInfo
        case fetchUserInfoDone(Int, Result<User, AppError>)
        case fetchGreeting
        case fetchGreetingResponse(Int, Result<Greeting, AppError>)
        case fetchGreetingDone(Result<Greeting, AppError>)
        case fetchTagTranslator
        case fetchTagTranslatorDone(Int, Result<TagTranslator, AppError>)
        case importTagTranslatorDone(Int, Result<TagTranslator, AppError>)
        case fetchEhProfileIndex
        case fetchEhProfileIndexDone(Int, Result<VerifyEhProfileResponse, AppError>)
        case fetchFavoriteCategories
        case fetchFavoriteCategoriesDone(Int, Result<[Int: String], AppError>)

        case account(AccountSettingReducer.Action)
        case general(GeneralSettingReducer.Action)
        case appearance(AppearanceSettingReducer.Action)
    }

    @Dependency(\.uiApplicationClient) private var uiApplicationClient
    @Dependency(\.userDefaultsClient) private var userDefaultsClient
    @Dependency(\.appDelegateClient) private var appDelegateClient
    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.libraryClient) private var libraryClient
    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.loggerClient) private var loggerClient
    @Dependency(\.cookieClient) private var cookieClient
    @Dependency(\.deviceClient) private var deviceClient
    @Dependency(\.fileClient) private var fileClient
    @Dependency(\.dfClient) private var dfClient

    var body: some Reducer<State, Action> {
        // None of the handlers below request a persistence sync. Every `setting` field is
        // written through one binding action, and the `.binding(\.$setting)` case is the
        // single trigger for the coalesced write, after these handlers have settled any
        // dependent fields. Sending it from here as well only duplicated the fan-out.
        BindingReducer()
            .onChange(of: \.setting.galleryHost) { _, newValue in
                Reduce { _, _ in
                    .run(operation: { _ in userDefaultsClient.setValue(newValue.rawValue, .galleryHost) })
                }
            }
            .onChange(of: \.setting.enablesTagsExtension) { _, newValue in
                Reduce { _, _ in
                    guard newValue else { return .none }
                    return .send(.fetchTagTranslator)
                }
            }
            .onChange(of: \.setting.preferredColorScheme) { _, _ in
                Reduce { _, _ in
                    .send(.syncUserInterfaceStyle)
                }
            }
            .onChange(of: \.setting.appIconType) { _, newValue in
                Reduce { _, _ in
                    // No `syncSetting` here on purpose: the requested icon must not be
                    // persisted before the system has accepted it. `syncAppIconType`
                    // reconciles against the icon actually in use and persists that.
                    .run { send in
                        _ = await uiApplicationClient.setAlternateIconName(newValue.filename)
                        await send(.syncAppIconType)
                    }
                }
            }
            .onChange(of: \.setting.autoLockPolicy) { _, newValue in
                Reduce { state, _ in
                    if newValue != .never && state.setting.backgroundBlurRadius == 0 {
                        state.setting.backgroundBlurRadius = 10
                    }
                    return .none
                }
            }
            .onChange(of: \.setting.backgroundBlurRadius) { _, newValue in
                Reduce { state, _ in
                    if state.setting.autoLockPolicy != .never && newValue == 0 {
                        state.setting.autoLockPolicy = .never
                    }
                    return .none
                }
            }
            .onChange(of: \.setting.enablesLandscape) { _, newValue in
                Reduce { _, _ in
                    guard !newValue, !deviceClient.isPad() else { return .none }
                    return .run(operation: { _ in appDelegateClient.setPortraitOrientationMask() })
                }
            }
            .onChange(of: \.setting.maximumScaleFactor) { _, newValue in
                Reduce { state, _ in
                    if state.setting.doubleTapScaleFactor > newValue {
                        state.setting.doubleTapScaleFactor = newValue
                    }
                    return .none
                }
            }
            .onChange(of: \.setting.doubleTapScaleFactor) { _, newValue in
                Reduce { state, _ in
                    if state.setting.maximumScaleFactor < newValue {
                        state.setting.maximumScaleFactor = newValue
                    }
                    return .none
                }
            }
            .onChange(of: \.setting.bypassesSNIFiltering) { _, newValue in
                Reduce { _, _ in
                    .merge(
                        .run(operation: { _ in hapticsClient.generateFeedback(.soft) }),
                        .run(operation: { _ in dfClient.setActive(newValue) })
                    )
                }
            }

        Reduce { state, action in
            switch action {
            case .binding(\.$setting):
                return .send(.syncSetting)

            case .binding(\.$route):
                return .none

            case .binding:
                return .merge(
                    .send(.syncUser(state.accountSessionGeneration)),
                    .send(.syncSetting),
                    .send(.syncTagTranslator)
                )

            case .setNavigation(let route):
                state.route = route
                return .none

            case .clearSubStates:
                state.accountSettingState = .init()
                state.generalSettingState = .init()
                state.appearanceSettingState = .init()
                return .none

            case .syncAppIconType:
                // A nil alternate icon name means the primary icon is in use, which is the
                // default type. Treating nil as "leave the requested value alone" is what
                // persisted a rejected icon request as if it had succeeded.
                let actualIconType = uiApplicationClient.alternateIconName().flatMap { iconName in
                    AppIconType.allCases.first(where: { iconName.contains($0.filename) })
                } ?? .default
                guard state.setting.appIconType != actualIconType else { return .none }
                state.setting.appIconType = actualIconType
                return .send(.syncSetting)

            case .syncUserInterfaceStyle:
                let style = state.setting.preferredColorScheme.userInterfaceStyle
                return .run(operation: { _ in await uiApplicationClient.setUserInterfaceStyle(style) })

            case .syncSetting:
                // Debounced and cancel-in-flight: the binding reducer, the per-field
                // `onChange` reducers and the app-level observer all funnel here, and a
                // slider or color picker would otherwise write the whole blob per sample.
                return .run { [setting = state.setting] _ in
                    try await Task.sleep(for: Self.settingSyncDelay)
                    let result = await databaseClient.updateSetting(setting)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist setting.", context: ["error": "\(error)"])
                    }
                }
                .cancellable(id: CancelID.syncSetting, cancelInFlight: true)
            case .syncTagTranslator:
                return .run { [state] _ in
                    let result = await databaseClient.updateTagTranslator(state.tagTranslator)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist tag translator.", context: ["error": "\(error)"])
                    }
                }
            case .syncUser(let generation):
                guard generation == state.accountSessionGeneration else { return .none }
                return .run { [user = state.user] _ in
                    try Task.checkCancellation()
                    let result = await databaseClient.updateUser(user)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist user.", context: ["error": "\(error)"])
                    }
                }
                .cancellable(id: CancelID.accountSession)

            case .loadUserSettings:
                return .run { send in
                    let appEnv = await databaseClient.fetchAppEnv()
                    await send(.onLoadUserSettings(appEnv))
                }

            case .onLoadUserSettings(let appEnv):
                state.setting = appEnv.setting
                state.tagTranslator = appEnv.tagTranslator
                state.user = appEnv.user
                var effects: [Effect<Action>] = [
                    .send(.syncAppIconType),
                    .send(.loadUserSettingsDone),
                    .send(.syncUserInterfaceStyle),
                    .run { [state] _ in
                        dfClient.setActive(state.setting.bypassesSNIFiltering)
                    }
                ]
                if let value: String = userDefaultsClient.getValue(.galleryHost),
                   let galleryHost = GalleryHost(rawValue: value)
                {
                    state.setting.galleryHost = galleryHost
                }
                if cookieClient.shouldFetchIgneous {
                    effects.append(.send(.fetchIgneous))
                }
                if cookieClient.didLogin {
                    effects.append(contentsOf: [
                        .send(.fetchUserInfo),
                        .send(.fetchGreeting),
                        .send(.fetchFavoriteCategories),
                        .send(.fetchEhProfileIndex)
                    ])
                }
                if state.setting.enablesTagsExtension {
                    effects.append(.send(.fetchTagTranslator))
                }
                return .merge(effects)

            case .loadUserSettingsDone:
                state.hasLoadedInitialSetting = true
                return .none

            case .createDefaultEhProfile:
                return .run { _ in
                    // Profile creation can now be reported as failed instead of always
                    // looking successful; there is no UI for it here, so record it rather
                    // than discarding the only evidence that the profile is missing.
                    let response = await EhProfileRequest(action: .create, name: "EhPanda").response()
                    if case .failure(let error) = response {
                        loggerClient.error("Failed in creating the default EhProfile.", error)
                    }
                }

            case .fetchIgneous:
                guard cookieClient.didLogin else { return .none }
                let generation = state.accountSessionGeneration
                return .run { send in
                    let response = await IgneousRequest().response()
                    await send(.fetchIgneousDone(generation, response))
                }
                .cancellable(id: CancelID.accountSession)

            case .fetchIgneousDone(let generation, let result):
                guard generation == state.accountSessionGeneration else { return .none }
                var effects = [Effect<Action>]()
                if case .success(let response) = result {
                    effects.append(.run(operation: { _ in cookieClient.setCredentials(response: response) }))
                }
                effects.append(.send(.account(.loadCookies)))
                return .merge(effects)

            case .fetchUserInfo:
                guard cookieClient.didLogin else { return .none }
                let uid = cookieClient
                    .getCookie(Defaults.URL.host, Defaults.Cookie.ipbMemberId).rawValue
                if !uid.isEmpty {
                    let generation = state.accountSessionGeneration
                    return .run { send in
                        let response = await UserInfoRequest(uid: uid).response()
                        await send(.fetchUserInfoDone(generation, response))
                    }
                    .cancellable(id: CancelID.accountSession)
                }
                return .none

            case .fetchUserInfoDone(let generation, let result):
                guard generation == state.accountSessionGeneration else { return .none }
                if case .success(let user) = result {
                    state.updateUser(user)
                    return .send(.syncUser(generation))
                }
                return .none

            case .fetchGreeting:
                func verifyDate(with updateTime: Date?) -> Bool {
                    guard let updateTime = updateTime else { return true }

                    let currentTime = Date()
                    let formatter = DateFormatter()
                    formatter.locale = Locale.current
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = Defaults.DateFormat.greeting

                    let currentTimeString = formatter.string(from: currentTime)
                    if let currentDay = formatter.date(from: currentTimeString) {
                        return currentTime > currentDay && updateTime < currentDay
                    }

                    return false
                }

                guard cookieClient.didLogin,
                      state.setting.showsNewDawnGreeting
                else { return .none }
                let generation = state.accountSessionGeneration
                let requestEffect = Effect.run { send in
                    let response = await GreetingRequest().response()
                    await send(Action.fetchGreetingResponse(generation, response))
                }
                .cancellable(id: CancelID.accountSession)
                if let greeting = state.user.greeting {
                    if verifyDate(with: greeting.updateTime) {
                        return requestEffect
                    }
                } else {
                    return requestEffect
                }
                return .none

            // The greeting is also observed by the app reducer, which presents it. Gating
            // the forward here keeps that payload-carrying action out of the app while a
            // response belongs to a session the user has already left.
            case .fetchGreetingResponse(let generation, let result):
                guard generation == state.accountSessionGeneration else { return .none }
                return .send(.fetchGreetingDone(result))

            case .fetchGreetingDone(let result):
                switch result {
                case .success(let greeting):
                    state.setGreeting(greeting)
                    return .send(.syncUser(state.accountSessionGeneration))
                case .failure(let error):
                    if case .parseFailed = error {
                        var greeting = Greeting()
                        greeting.updateTime = Date()
                        state.setGreeting(greeting)
                        return .send(.syncUser(state.accountSessionGeneration))
                    }
                }
                return .none

            case .fetchTagTranslator:
                guard state.tagTranslatorLoadingState != .loading,
                      !state.tagTranslator.hasCustomTranslations,
                      let language = TranslatableLanguage.current
                else { return .none }
                state.tagTranslatorLoadingState = .loading

                var databaseEffect: Effect<Action>?
                if state.tagTranslator.language != language {
                    state.tagTranslator = TagTranslator(language: language)
                    databaseEffect = .send(.syncTagTranslator)
                }
                state.tagTranslatorGeneration += 1
                let generation = state.tagTranslatorGeneration
                let updatedDate = state.tagTranslator.updatedDate
                let requestEffect = Effect.run { send in
                    let response = await TagTranslatorRequest(language: language, updatedDate: updatedDate).response()
                    await send(Action.fetchTagTranslatorDone(generation, response))
                }
                .cancellable(id: CancelID.tagTranslatorRequest, cancelInFlight: true)
                if let databaseEffect = databaseEffect {
                    return .merge(databaseEffect, requestEffect)
                } else {
                    return requestEffect
                }

            case .fetchTagTranslatorDone(let generation, let result):
                guard generation == state.tagTranslatorGeneration,
                      !state.tagTranslator.hasCustomTranslations
                else { return .none }
                state.tagTranslatorLoadingState = .idle
                switch result {
                case .success(let tagTranslator):
                    state.tagTranslator = tagTranslator
                    return .send(.syncTagTranslator)
                case .failure(let error):
                    state.tagTranslatorLoadingState = .failed(error)
                }
                return .none

            case .fetchEhProfileIndex:
                guard cookieClient.didLogin else { return .none }
                let generation = state.accountSessionGeneration
                return .run { send in
                    let response = await VerifyEhProfileRequest().response()
                    await send(.fetchEhProfileIndexDone(generation, response))
                }
                .cancellable(id: CancelID.accountSession)

            case .fetchEhProfileIndexDone(let generation, let result):
                guard generation == state.accountSessionGeneration else { return .none }
                var effects = [Effect<Action>]()

                if case .success(let response) = result {
                    if let profileValue = response.profileValue {
                        let hostURL = Defaults.URL.host
                        let profileValueString = String(profileValue)
                        let selectedProfileKey = Defaults.Cookie.selectedProfile

                        let cookieValue = cookieClient.getCookie(hostURL, selectedProfileKey)
                        if cookieValue.rawValue != profileValueString {
                            effects.append(
                                .run { _ in
                                    cookieClient.setOrEditCookie(
                                        for: hostURL, key: selectedProfileKey, value: profileValueString
                                    )
                                }
                            )
                        }
                    } else if response.isProfileNotFound {
                        effects.append(.send(.createDefaultEhProfile))
                    } else {
                        let message = "Found profile but failed in parsing value."
                        effects.append(.run(operation: { _ in loggerClient.error(message, nil) }))
                    }
                }
                return effects.isEmpty ? .none : .merge(effects)

            case .fetchFavoriteCategories:
                guard cookieClient.didLogin else { return .none }
                let generation = state.accountSessionGeneration
                return .run { send in
                    let response = await FavoriteCategoriesRequest().response()
                    await send(.fetchFavoriteCategoriesDone(generation, response))
                }
                .cancellable(id: CancelID.accountSession)

            case .fetchFavoriteCategoriesDone(let generation, let result):
                guard generation == state.accountSessionGeneration else { return .none }
                if case .success(let categories) = result {
                    state.user.favoriteCategories = categories
                }
                return .none

            // Credentials and the cross-host cookie sync are already installed by the login
            // reducer at this point, so every fetch below observes the new session. The
            // generation is advanced first and the previous session's effects are torn
            // down, so nothing left over from the previous account can land in this one.
            case .account(.login(.onCredentialsInstalled)):
                guard cookieClient.didLogin else { return .none }
                state.accountSessionGeneration += 1
                state.user = User()
                return .concatenate(
                    .cancel(id: CancelID.accountSession),
                    .merge(
                        .send(.syncUser(state.accountSessionGeneration)),
                        .send(.fetchIgneous),
                        .send(.fetchUserInfo),
                        .send(.fetchFavoriteCategories),
                        .send(.fetchEhProfileIndex)
                    )
                )

            case .account(.onLogoutConfirmButtonTapped):
                state.accountSessionGeneration += 1
                state.user = User()
                return .concatenate(
                    .cancel(id: CancelID.accountSession),
                    .merge(
                        .send(.syncUser(state.accountSessionGeneration)),
                        .run { send in
                            // Strictly ordered: the cookies have to be gone before the account
                            // screen reloads its state, otherwise the reload restores the very
                            // secrets the logout was meant to destroy.
                            cookieClient.clearAll()
                            await send(.account(.loadCookies))
                        },
                        .run { _ in
                            await libraryClient.clearWebImageCache()
                            let result = await databaseClient.removeImageURLs()
                            if case .failure(let error) = result {
                                Logger.error("Failed to remove cached image URLs on logout.", context: [
                                    "error": "\(error)"
                                ])
                            }
                        }
                    )
                )

            case .account:
                return .none

            case .general(.onTranslationsFilePicked(let url)):
                state.tagTranslatorGeneration += 1
                let generation = state.tagTranslatorGeneration
                return .run { send in
                    let result = await fileClient.importTagTranslator(url)
                    await send(.importTagTranslatorDone(generation, result))
                }
                .cancellable(id: CancelID.tagTranslatorRequest, cancelInFlight: true)

            case .importTagTranslatorDone(let generation, let result):
                guard generation == state.tagTranslatorGeneration else { return .none }
                state.tagTranslatorLoadingState = .idle
                switch result {
                case .success(let tagTranslator):
                    state.tagTranslator = tagTranslator
                    return .merge(
                        .cancel(id: CancelID.tagTranslatorRequest),
                        .send(.syncTagTranslator)
                    )
                case .failure(let error):
                    state.tagTranslatorLoadingState = .failed(error)
                }
                return .none

            case .general(.onRemoveCustomTranslations):
                // Replacing the translator rather than emptying it also resets `updatedDate`;
                // otherwise the refetch below is answered with `.noUpdates` and the feature
                // stays empty until the toggle is cycled or the app is relaunched.
                state.tagTranslator = TagTranslator(language: TranslatableLanguage.current)
                state.tagTranslatorGeneration += 1
                var effects: [Effect<Action>] = [.send(.syncTagTranslator)]
                if state.setting.enablesTagsExtension {
                    effects.append(.send(.fetchTagTranslator))
                }
                return .merge(effects)

            case .general:
                return .none

            case .appearance:
                return .none
            }
        }

        Scope(state: \.accountSettingState, action: /Action.account, child: AccountSettingReducer.init)
        Scope(state: \.generalSettingState, action: /Action.general, child: GeneralSettingReducer.init)
        Scope(state: \.appearanceSettingState, action: /Action.appearance, child: AppearanceSettingReducer.init)
    }
}
