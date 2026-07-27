//
//  LoginReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/01.
//

import SwiftUI
import ComposableArchitecture

struct LoginReducer: Reducer {
    private enum CancelID: Hashable {
        case login
    }

    enum Route: Equatable {
        case webView(URL)
    }

    enum FocusedField {
        case username
        case password
    }

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var focusedField: FocusedField?
        @BindingState var username = ""
        @BindingState var password = ""
        var loginState: LoadingState = .idle

        var loginButtonDisabled: Bool {
            username.isEmpty || password.isEmpty
        }
        var loginButtonColor: Color {
            loginState == .loading ? .clear : loginButtonDisabled
            ? .primary.opacity(0.25) : .primary.opacity(0.75)
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case setNavigation(Route?)

        case teardown
        case login
        case loginDone(Result<HTTPURLResponse?, AppError>)
        case onCredentialsInstalled
    }

    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.cookieClient) private var cookieClient

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return .none

            case .teardown:
                return .cancel(id: CancelID.login)

            case .login:
                guard !state.loginButtonDisabled, state.loginState != .loading else { return .none }
                state.focusedField = nil
                state.loginState = .loading
                return .merge(
                    .run(operation: { _ in hapticsClient.generateFeedback(.soft) }),
                    .run { [state] send in
                        let response = await LoginRequest(username: state.username, password: state.password).response()
                        await send(.loginDone(response))
                    }
                    .cancellable(id: CancelID.login, cancelInFlight: true)
                )

            case .loginDone(let result):
                state.route = nil
                // Credential installation and cross-host cookie sync must complete before
                // anything observes `didLogin` or issues an authenticated request. Merging
                // them alongside the outcome, as before, let the parent's authenticated
                // fetches start against a session that had not been written yet.
                return .run { send in
                    if case .success(let response) = result, let response = response {
                        cookieClient.setCredentials(response: response)
                    }
                    cookieClient.removeYay()
                    cookieClient.syncExCookies()
                    cookieClient.fulfillAnotherHostField()
                    await send(.onCredentialsInstalled)
                }

            case .onCredentialsInstalled:
                if cookieClient.didLogin {
                    state.loginState = .idle
                    // The credentials are installed; the typed ones must not linger in
                    // observable state any longer than the request needs them.
                    state.username = ""
                    state.password = ""
                    return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.success) })
                } else {
                    state.loginState = .failed(.unknown)
                    return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })
                }
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.webView,
            hapticsClient: hapticsClient
        )
    }
}
