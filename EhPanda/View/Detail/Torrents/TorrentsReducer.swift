//
//  TorrentsReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/19.
//

import Foundation
import ComposableArchitecture

struct TorrentsReducer: Reducer {
    enum Route: Equatable {
        case hud
        case share(URL)
    }

    /// Scoped to the state instance so one torrents sheet's teardown cannot cancel another's.
    private enum CancelIdentifier: CaseIterable {
        case fetchTorrent, fetchGalleryTorrents
    }

    private struct CancelID: Hashable {
        let instanceID: UUID
        let identifier: CancelIdentifier
    }

    struct State: Equatable {
        @BindingState var route: Route?
        var instanceID = UUID()
        var torrents = [GalleryTorrent]()
        var loadingState: LoadingState = .idle
        /// Hash of the torrent currently being downloaded, so the row can show progress and
        /// a second tap cannot start the same download twice.
        var downloadingTorrentHash: String?
        var hudConfig: AppToastConfig = .copiedToClipboardSucceeded
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case setNavigation(Route)

        case copyText(String)
        case presentTorrentActivity(String, Data)

        case teardown
        case fetchTorrent(String, URL)
        case fetchTorrentDone(String, Result<Data, AppError>)
        case fetchGalleryTorrents(String, String)
        case fetchGalleryTorrentsDone(Result<[GalleryTorrent], AppError>)
    }

    @Dependency(\.clipboardClient) private var clipboardClient
    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.fileClient) private var fileClient

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return .none

            case .copyText(let magnetURL):
                state.hudConfig = .copiedToClipboardSucceeded
                state.route = .hud
                return .merge(
                    .run(operation: { _ in clipboardClient.saveText(magnetURL) }),
                    .run(operation: { _ in hapticsClient.generateNotificationFeedback(.success) })
                )

            case .presentTorrentActivity(let hash, let data):
                guard let url = fileClient.saveTorrent(hash: hash, data: data) else {
                    // Writing the torrent failed: the button must not just do nothing.
                    state.hudConfig = .error(caption: AppError.notFound.alertText)
                    state.route = .hud
                    return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })
                }
                return .send(.setNavigation(.share(url)))

            case .fetchTorrent(let hash, let torrentURL):
                guard state.downloadingTorrentHash == nil else { return .none }
                state.downloadingTorrentHash = hash
                return .run { send in
                    let response = await DataRequest(url: torrentURL).response()
                    await send(.fetchTorrentDone(hash, response))
                }
                .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .fetchTorrent))

            case .teardown:
                let effects: [Effect<Action>] = CancelIdentifier.allCases.map {
                    .cancel(id: CancelID(instanceID: state.instanceID, identifier: $0))
                }
                return .merge(effects)

            case .fetchTorrentDone(let hash, let result):
                state.downloadingTorrentHash = nil
                switch result {
                case .success(let data) where !data.isEmpty:
                    return .send(.presentTorrentActivity(hash, data))
                case .success:
                    // An empty body is a failed download, not a torrent worth sharing.
                    state.hudConfig = .error(caption: AppError.notFound.alertText)
                case .failure(let error):
                    state.hudConfig = .error(caption: error.alertText)
                }
                state.route = .hud
                return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })

            case .fetchGalleryTorrents(let gid, let token):
                guard state.loadingState != .loading else { return .none }
                state.loadingState = .loading
                return .run { send in
                    let response = await GalleryTorrentsRequest(gid: gid, token: token).response()
                    await send(.fetchGalleryTorrentsDone(response))
                }
                .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .fetchGalleryTorrents))

            case .fetchGalleryTorrentsDone(let result):
                state.loadingState = .idle
                switch result {
                case .success(let torrents):
                    guard !torrents.isEmpty else {
                        state.loadingState = .failed(.notFound)
                        return .none
                    }
                    state.torrents = torrents
                case .failure(let error):
                    state.loadingState = .failed(error)
                }
                return .none
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.share,
            hapticsClient: hapticsClient
        )
    }
}
