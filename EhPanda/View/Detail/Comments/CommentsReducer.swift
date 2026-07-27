//
//  CommentsReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/16.
//

import Foundation
import ComposableArchitecture

struct CommentsReducer: Reducer {
    enum Route: Equatable {
        case hud
        case detail(String)
        case postComment(String)
    }

    /// Scoped to the state instance: a detail nested inside comments hosts another comments
    /// feature, and a shared static key let one instance's teardown cancel the other's work.
    private enum CancelIdentifier: CaseIterable {
        case postComment, voteComment, fetchGallery
    }

    private struct CancelID: Hashable {
        let instanceID: UUID
        let identifier: CancelIdentifier
    }

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var commentContent = ""
        @BindingState var postCommentFocused = false

        let instanceID: UUID
        var hudConfig: AppToastConfig = .loading
        var postCommentLoadingState: LoadingState = .idle
        var scrollCommentID: String?
        var scrollRowOpacity: Double = 1

        @Heap var detailState: DetailReducer.State!

        init(instanceID: UUID = .init()) {
            self.instanceID = instanceID
            _detailState = .init(.init())
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates
        case clearScrollCommentID

        case setHUDConfig(AppToastConfig)
        case setPostCommentFocused(Bool)
        case setScrollRowOpacity(Double)
        case setCommentContent(String)
        case performScrollOpacityEffect
        case handleCommentLink(URL)
        case handleGalleryLink(URL)
        case onPostCommentAppear
        case onAppear

        case updateReadingProgress(String, Int)

        case teardown
        case postComment(URL, String? = nil)
        case postCommentDone(Result<Any, AppError>)
        case voteComment(String, String, String, String, Int)
        case voteCommentDone(Result<Any, AppError>)
        case fetchGallery(URL, Bool)
        case fetchGalleryDone(URL, Result<Gallery, AppError>)

        case detail(DetailReducer.Action)
    }

    @Dependency(\.uiApplicationClient) private var uiApplicationClient
    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.cookieClient) private var cookieClient
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

            case .clearSubStates:
                // Keep the nested detail's cancellation identity — and those of its own sub
                // features — so the teardown below still reaches every request the replaced
                // state started.
                if let previous = state.detailState {
                    state.detailState = .init(replacing: previous)
                } else {
                    state.detailState = .init()
                }
                state.commentContent = .init()
                state.postCommentFocused = false
                state.postCommentLoadingState = .idle
                return .send(.detail(.teardown))

            case .clearScrollCommentID:
                state.scrollCommentID = nil
                return .none

            case .setHUDConfig(let config):
                state.hudConfig = config
                return .none

            case .setPostCommentFocused(let isFocused):
                state.postCommentFocused = isFocused
                return .none

            case .setScrollRowOpacity(let opacity):
                state.scrollRowOpacity = opacity
                return .none

            case .setCommentContent(let content):
                state.commentContent = content
                return .none

            case .performScrollOpacityEffect:
                return .merge(
                    .run { send in
                        try await Task.sleep(for: .milliseconds(750))
                        await send(.setScrollRowOpacity(0.25))
                    },
                    .run { send in
                        try await Task.sleep(for: .milliseconds(1250))
                        await send(.setScrollRowOpacity(1))
                    },
                    .run { send in
                        try await Task.sleep(for: .milliseconds(2000))
                        await send(.clearScrollCommentID)
                    }
                )

            case .handleCommentLink(let url):
                guard urlClient.checkIfHandleable(url) else {
                    return .run(operation: { _ in await uiApplicationClient.openURL(url) })
                }
                let (isGalleryImageURL, _, _) = urlClient.analyzeURL(url)
                let gid = urlClient.parseGalleryID(url)
                guard databaseClient.fetchGallery(gid: gid) == nil else {
                    return .send(.handleGalleryLink(url))
                }
                return .send(.fetchGallery(url, isGalleryImageURL))

            case .handleGalleryLink(let url):
                let (_, pageIndex, commentID) = urlClient.analyzeURL(url)
                let gid = urlClient.parseGalleryID(url)
                var effects = [Effect<Action>]()
                if let pageIndex = pageIndex {
                    effects.append(.send(.updateReadingProgress(gid, pageIndex)))
                    effects.append(
                        .run { send in
                            try await Task.sleep(for: .milliseconds(750))
                            await send(.detail(.setNavigation(.reading)))
                        }
                    )
                } else if let commentID = commentID {
                    state.detailState.commentsState?.scrollCommentID = commentID
                    effects.append(
                        .run { send in
                            try await Task.sleep(for: .milliseconds(750))
                            await send(.detail(.setNavigation(.comments(url))))
                        }
                    )
                }
                effects.append(.send(.setNavigation(.detail(gid))))
                return .merge(effects)

            case .onPostCommentAppear:
                return .run { send in
                    try await Task.sleep(for: .milliseconds(750))
                    await send(.setPostCommentFocused(true))
                }

            case .onAppear:
                if state.detailState == nil {
                    state.detailState = .init()
                }
                return state.scrollCommentID != nil ? .send(.performScrollOpacityEffect) : .none

            case .updateReadingProgress(let gid, let progress):
                guard !gid.isEmpty else { return .none }
                return .run { _ in
                    let result = await databaseClient.updateReadingProgress(gid: gid, progress: progress)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist comment reading progress.", context: [
                            "gid": gid, "progress": progress, "error": "\(error)"
                        ])
                    }
                }

            case .teardown:
                let effects: [Effect<Action>] = CancelIdentifier.allCases.map {
                    .cancel(id: CancelID(instanceID: state.instanceID, identifier: $0))
                }
                return .merge(effects)

            case .postComment(let galleryURL, let commentID):
                guard !state.commentContent.isEmpty,
                      state.postCommentLoadingState != .loading
                else { return .none }
                state.postCommentLoadingState = .loading
                let cancelID = CancelID(instanceID: state.instanceID, identifier: .postComment)
                if let commentID = commentID {
                    return .run { [commentContent = state.commentContent] send in
                        let response = await EditGalleryCommentRequest(
                            commentID: commentID,
                            content: commentContent,
                            galleryURL: galleryURL
                        )
                        .response()
                        await send(.postCommentDone(response))
                    }
                    .cancellable(id: cancelID)
                } else {
                    return .run { [commentContent = state.commentContent] send in
                        let response = await CommentGalleryRequest(
                            content: commentContent, galleryURL: galleryURL
                        )
                        .response()
                        await send(.postCommentDone(response))
                    }
                    .cancellable(id: cancelID)
                }

            case .postCommentDone(let result):
                switch result {
                case .success:
                    // Only a confirmed post may discard what the user typed, and never a draft
                    // that was retyped after the sheet had already been dismissed.
                    if state.postCommentLoadingState == .loading {
                        state.postCommentLoadingState = .idle
                        state.commentContent = .init()
                        state.postCommentFocused = false
                        state.route = nil
                    }
                    return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.success) })
                case .failure(let error):
                    // Keep the sheet and the draft; the sheet renders the reason.
                    guard state.postCommentLoadingState == .loading else { return .none }
                    state.postCommentLoadingState = .failed(error)
                    return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })
                }

            case .voteComment(let gid, let token, let apiKey, let commentID, let vote):
                // An empty API key makes the vote guaranteed invalid.
                guard !apiKey.isEmpty, let gid = Int(gid), let commentID = Int(commentID),
                      let apiuid = Int(cookieClient.apiuid)
                else { return .none }
                return .run {  send in
                    let response = await VoteGalleryCommentRequest(
                        apiuid: apiuid,
                        apikey: apiKey,
                        gid: gid,
                        token: token,
                        commentID: commentID,
                        commentVote: vote
                    )
                    .response()
                    await send(.voteCommentDone(response))
                }
                .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .voteComment))

            case .voteCommentDone(let result):
                guard case .failure(let error) = result else {
                    return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.success) })
                }
                state.hudConfig = .error(caption: error.alertText)
                state.route = .hud
                return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })

            case .fetchGallery(let url, let isGalleryImageURL):
                state.hudConfig = .loading
                state.route = .hud
                return .run {  send in
                    let response = await GalleryReverseRequest(
                        url: url, isGalleryImageURL: isGalleryImageURL
                    )
                    .response()
                    await send(.fetchGalleryDone(url, response))
                }
                .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .fetchGallery))

            case .fetchGalleryDone(let url, let result):
                state.route = nil
                switch result {
                case .success(let gallery):
                    return .run { send in
                        let result = await databaseClient.cacheGalleries([gallery])
                        switch result {
                        case .success:
                            await send(.handleGalleryLink(url))
                        case .failure(let error):
                            Logger.error("Failed to cache comment reverse lookup gallery.", context: [
                                "gid": gallery.id, "error": "\(error)"
                            ])
                            await send(.setHUDConfig(.error))
                            await send(.setNavigation(.hud))
                        }
                    }
                case .failure:
                    return .run { send in
                        try await Task.sleep(for: .milliseconds(500))
                        await send(.setHUDConfig(.error))
                        await send(.setNavigation(.hud))
                    }
                }

            case .detail:
                return .none
            }
        }
        .haptics(
            unwrapping: \.route,
            case: /Route.postComment,
            hapticsClient: hapticsClient
        )
    }
}
