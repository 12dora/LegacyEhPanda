//
//  Reducer_Extension.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/02.
//

import SwiftUI
import ComposableArchitecture

extension Reducer {
    func haptics<Enum, Case>(
        unwrapping enum: @escaping (State) -> Enum?,
        case casePath: AnyCasePath<Enum, Case>,
        hapticsClient: HapticsClient,
        style: UIImpactFeedbackGenerator.FeedbackStyle = .light
    ) -> some Reducer<State, Action> {
        onBecomeNonNil(unwrapping: `enum`, case: casePath) { _, _ in
            .run(operation: { _ in hapticsClient.generateFeedback(style) })
        }
    }

    private func onBecomeNonNil<Enum, Case>(
        unwrapping enum: @escaping (State) -> Enum?,
        case casePath: AnyCasePath<Enum, Case>,
        perform additionalEffects: @escaping (inout State, Action) -> Effect<Action>
    ) -> some Reducer<State, Action> {
        Reduce { state, action in
            let previousCase = Binding.constant(`enum`(state)).case(casePath).wrappedValue
            let effects = reduce(into: &state, action: action)
            let currentCase = Binding.constant(`enum`(state)).case(casePath).wrappedValue

            return previousCase == nil && currentCase != nil
            ? .merge(effects, additionalEffects(&state, action))
            : effects
        }
    }
}

// MARK: Recurse
struct RecurseReducer<State, Action, Base: Reducer>: Reducer
where State == Base.State, Action == Base.Action {
    let base: (Reduce<State, Action>) -> Base

    public init(@ReducerBuilder<State, Action> base: @escaping (Reduce<State, Action>) -> Base) {
        self.base = base
    }

    public var body: some Reducer<State, Action> {
        var `self`: Reduce<State, Action>!
        self = Reduce { state, action in
            base(self).reduce(into: &state, action: action)
        }
        return self
    }
}

// MARK: Logging
struct LoggingReducer<State, Action, Base: Reducer>: Reducer
where State == Base.State, Action == Base.Action {
    let base: Base

    init(@ReducerBuilder<State, Action> base: () -> Base) {
        self.base = base()
    }

    @ReducerBuilder<State, Action>
    var body: some Reducer<State, Action> {
        Reduce { state, action in
            if let event = Self.allowListedEvent(action) {
                Logger.info(event)
            }
            return base.reduce(into: &state, action: action)
        }
    }

    // Actions carry user content: login and cookie bindings hold plaintext passwords and
    // reusable session cookies, and search/comment actions hold private text. Formatting
    // every action reflected those values into a release file destination that keeps ten
    // files in the file-sharing enabled Documents directory, and it added a per-action
    // formatting cost to hot reader paths. Only payload-free lifecycle events are named
    // here, and never their associated values.
    private static func allowListedEvent(_ action: Action) -> String? {
        guard let action = action as? AppReducer.Action else { return nil }
        switch action {
        case .onScenePhaseChange(let scenePhase):
            return "app.scenePhase.\(scenePhase)"
        case .appDelegate(.onLaunchFinish):
            return "app.launchFinished"
        case .appDelegate(.migration(.onDatabasePreparationSuccess)):
            return "app.databaseReady"
        case .appLock(.lockApp):
            return "appLock.locked"
        case .appLock(.unlockApp):
            return "appLock.unlocked"
        case .setting(.loadUserSettingsDone):
            return "setting.userSettingsLoaded"
        case .setting(.account(.login(.onCredentialsInstalled))):
            return "account.credentialsInstalled"
        case .setting(.account(.onLogoutConfirmButtonTapped)):
            return "account.loggedOut"
        default:
            return nil
        }
    }
}
