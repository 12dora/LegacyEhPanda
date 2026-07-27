//
//  EhPandaApp.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 2/10/28.
//

import SwiftUI
import ComposableArchitecture

@main struct EhPandaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView(store: appDelegate.store)
        }
    }
}

// MARK: RootView
/// The root of every scene.
///
/// Scene lifecycle and custom scheme URLs are handled here instead of in `TabBarView`, which does
/// not exist while the database is being prepared: launching the terminated app through
/// `ehpanda://` would otherwise open it and silently drop the requested gallery. Each scene also
/// reports its phase under its own identity, so one window cannot lock or blur another.
private struct RootView: View {
    private struct ViewState: Equatable {
        let databaseState: LoadingState
        let colorScheme: ColorScheme?

        init(_ state: AppReducer.State) {
            databaseState = state.appDelegateState.migrationState.databaseState
            colorScheme = state.settingState.setting.preferredColorScheme.sceneColorScheme
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneID = UUID()

    private let store: StoreOf<AppReducer>
    @ObservedObject private var viewStore: ViewStore<ViewState, AppReducer.Action>

    init(store: StoreOf<AppReducer>) {
        self.store = store
        viewStore = ViewStore(store, observe: ViewState.init)
    }

    var body: some View {
        ZStack {
            if viewStore.databaseState == .idle {
                TabBarView(store: store).onAppear(perform: addTouchHandler).accentColor(.primary)
            }
            MigrationView(
                store: store.scope(
                    state: \.appDelegateState.migrationState,
                    action: { AppReducer.Action.appDelegate(.migration($0)) }
                )
            )
            .opacity(viewStore.databaseState != .idle ? 1 : 0)
            .animation(.linear(duration: 0.5), value: viewStore.databaseState)
        }
        .navigationViewStyle(.stack)
        // The theme belongs to the scene: overriding the style of the windows that happen to be
        // connected leaves a window opened after the change on the system appearance.
        .preferredColorScheme(viewStore.colorScheme)
        .onChange(of: scenePhase) { viewStore.send(.onSceneChange(sceneID, $0)) }
        .onOpenURL { viewStore.send(.onOpenURL($0)) }
        .onDisappear { viewStore.send(.onSceneDisappear(sceneID)) }
    }
}

private extension PreferredColorScheme {
    /// The scene level equivalent of `userInterfaceStyle`, where `nil` follows the system.
    var sceneColorScheme: ColorScheme? {
        switch userInterfaceStyle {
        case .light:
            return .light
        case .dark:
            return .dark
        default:
            return nil
        }
    }
}

// MARK: TouchHandler
final class TouchHandler: NSObject, UIGestureRecognizerDelegate {
    static let shared = TouchHandler()
    var currentPoint: CGPoint?

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        currentPoint = touch.location(in: touch.window)
        return false
    }
}
private extension RootView {
    func addTouchHandler() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let tapGesture = UITapGestureRecognizer(
                target: self, action: nil
            )
            tapGesture.delegate = TouchHandler.shared
            DeviceUtil.keyWindow?.addGestureRecognizer(tapGesture)
        }
    }
}
