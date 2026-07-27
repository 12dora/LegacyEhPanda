//
//  DetailReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/10.
//

import SwiftUI
import Foundation
import ComposableArchitecture

struct DetailReducer: Reducer {
    enum Route: Equatable {
        case hud
        case reading
        case archives(URL, URL)
        case torrents
        case previews
        case comments(URL)
        case share(URL)
        case postComment
        case newDawn(Greeting)
        case detailSearch(String)
        case tagDetail(TagDetail)
        case galleryInfos(Gallery, GalleryDetail)
    }

    /// Cancellation identity is scoped to the state instance: several `DetailReducer`s are
    /// alive at once (app route, each list, nested comment detail) and a shared static key made
    /// one instance's teardown cancel another instance's in-flight requests.
    private enum CancelIdentifier: CaseIterable {
        case fetchDatabaseInfos, fetchGalleryDetail, rateGallery
        case favorGallery, unfavorGallery, postComment, voteTag
    }

    private struct CancelID: Hashable {
        let instanceID: UUID
        let identifier: CancelIdentifier
    }

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var commentContent = ""
        @BindingState var postCommentFocused = false

        /// Identifies this feature instance so cancellation never crosses instances.
        /// Pass the previous instance's identifier when replacing a state whose effects
        /// still have to be torn down, otherwise `teardown` cannot reach them.
        let instanceID: UUID

        var showsNewDawnGreeting = false
        var showsUserRating = false
        var showsFullTitle = false
        var userRating = 0

        var apiKey = ""
        var loadingState: LoadingState = .idle
        var postCommentLoadingState: LoadingState = .idle
        var gallery: Gallery = .empty
        var galleryDetail: GalleryDetail?
        var galleryTags = [GalleryTag]()
        var galleryPreviewURLs = [Int: URL]()
        var galleryComments = [GalleryComment]()
        var previewConfig: PreviewConfig = .normal(rows: 4)
        var hudConfig = AppToastConfig.success(
            caption: L10n.Localizable.DownloadsView.Toast.queued
        )

        var readingState = ReadingReducer.State()
        var archivesState = ArchivesReducer.State()
        var torrentsState = TorrentsReducer.State()
        var previewsState = PreviewsReducer.State()
        @Heap var commentsState: CommentsReducer.State?
        var galleryInfosState = GalleryInfosReducer.State()
        @Heap var detailSearchState: DetailSearchReducer.State?

        init(instanceID: UUID = .init()) {
            self.instanceID = instanceID
            _commentsState = .init(nil)
            _detailSearchState = .init(nil)
        }

        /// Builds the state that takes `previous`'s place in the same navigation slot: every
        /// gallery-level value starts empty, but this feature's *and* its sub features'
        /// cancellation identities are carried over. Without that carry-over the `teardown`
        /// that accompanies a replacement reduces against fresh identities, so an archives,
        /// torrents or previews response that was already in flight survives and writes the
        /// previous gallery's data into the replacement.
        init(replacing previous: State) {
            self.init(instanceID: previous.instanceID)
            adoptSubStateIdentities(from: previous)
        }

        /// Rating and voting endpoints are only valid once the gallery page handed us an API
        /// key; cached state alone enables the controls while the key is still empty.
        var isAPIReady: Bool {
            !apiKey.isEmpty
        }

        mutating func updateRating(value: DragGesture.Value) {
            let rating = Int(value.location.x / 31 * 2) + 1
            userRating = min(max(rating, 1), 10)
        }

        /// Single conversion from the server's star rating to the half-star control's scale,
        /// shared by the cached and the refreshed path so 4.5 never collapses to 4.0.
        static func halfStars(from rating: Float) -> Int {
            min(max(Int((rating * 2).rounded()), 0), 10)
        }

        /// The single list of sub features that own a cancellation identity: each is re-created
        /// empty while keeping the identity `source` used, so a `teardown` issued afterwards
        /// still reaches the requests those sub features had started. A new sub feature with an
        /// `instanceID` has to be added here — `resetSubStatesPreservingIdentity()` and
        /// `init(replacing:)` both go through it.
        ///
        /// `readingState`, `galleryInfosState` and `detailSearchState` are omitted on purpose:
        /// they cancel through static keys and have no identity to preserve.
        private mutating func adoptSubStateIdentities(from source: State) {
            archivesState = .init(instanceID: source.archivesState.instanceID)
            torrentsState = .init(instanceID: source.torrentsState.instanceID)
            previewsState = .init(instanceID: source.previewsState.instanceID)
            commentsState = .init(instanceID: source.commentsState?.instanceID ?? UUID())
        }

        /// Replaces every sub state while keeping their cancellation identities, so the
        /// teardown that follows still cancels the effects those sub states started.
        mutating func resetSubStatesPreservingIdentity() {
            let previous = self
            readingState = .init()
            adoptSubStateIdentities(from: previous)
            commentContent = .init()
            postCommentFocused = false
            postCommentLoadingState = .idle
            galleryInfosState = .init()
            detailSearchState = .init()
        }
    }

    indirect enum Action: BindableAction {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates
        case onPostCommentAppear
        case onAppear(String, Bool)

        case toggleShowFullTitle
        case toggleShowUserRating
        case setCommentContent(String)
        case setPostCommentFocused(Bool)
        case updateRating(DragGesture.Value)
        case confirmRating(DragGesture.Value)
        case confirmRatingDone

        case syncGalleryTags
        case syncGalleryDetail
        case syncGalleryPreviewURLs
        case syncGalleryComments
        case syncGreeting(Greeting)
        case syncPreviewConfig(PreviewConfig)
        case saveGalleryHistory
        case updateReadingProgress(Int)
        case navigateReading(Int)
        case downloadGallery

        case teardown
        case fetchDatabaseInfos(String)
        case fetchDatabaseInfosDone(GalleryState)
        case fetchDatabaseInfosFailed(String)
        case fetchGalleryDetail
        case fetchGalleryDetailDone(String, Result<(GalleryDetail, GalleryState, String, Greeting?), AppError>)

        case rateGallery
        case favorGallery(Int)
        case unfavorGallery
        case postComment(URL)
        case postCommentDone(Result<Any, AppError>)
        case voteTag(String, Int)
        case anyGalleryOpsDone(Result<Any, AppError>)

        case reading(ReadingReducer.Action)
        case archives(ArchivesReducer.Action)
        case torrents(TorrentsReducer.Action)
        case previews(PreviewsReducer.Action)
        case comments(CommentsReducer.Action)
        case galleryInfos(GalleryInfosReducer.Action)
        case detailSearch(DetailSearchReducer.Action)
    }

    @Dependency(\.databaseClient) private var databaseClient
    @Dependency(\.hapticsClient) private var hapticsClient
    @Dependency(\.cookieClient) private var cookieClient

    /// How long a freshly opened detail waits for the list's background cache write to land
    /// before it declares the gallery genuinely missing.
    private static let galleryCacheRetryCount = 8
    private static let galleryCacheRetryInterval = 250

    private func teardownEffect(instanceID: UUID) -> Effect<Action> {
        var effects: [Effect<Action>] = CancelIdentifier.allCases.map {
            .cancel(id: CancelID(instanceID: instanceID, identifier: $0))
        }
        effects.append(contentsOf: [
            .send(.reading(.teardown)),
            .send(.archives(.teardown)),
            .send(.torrents(.teardown)),
            .send(.previews(.teardown)),
            .send(.comments(.teardown)),
            .send(.detailSearch(.teardown))
        ])
        return .merge(effects)
    }

    var body: some Reducer<State, Action> {
        RecurseReducer { (self) in
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
                    state.resetSubStatesPreservingIdentity()
                    return .merge(
                        .send(.reading(.teardown)),
                        .send(.archives(.teardown)),
                        .send(.torrents(.teardown)),
                        .send(.previews(.teardown)),
                        .send(.comments(.teardown)),
                        .send(.detailSearch(.teardown))
                    )

                case .onPostCommentAppear:
                    return .run { send in
                        try await Task.sleep(for: .milliseconds(750))
                        await send(.setPostCommentFocused(true))
                    }

                case .onAppear(let gid, let showsNewDawnGreeting):
                    state.showsNewDawnGreeting = showsNewDawnGreeting
                    if state.detailSearchState == nil {
                        state.detailSearchState = .init()
                    }
                    if state.commentsState == nil {
                        state.commentsState = .init()
                    }
                    return .send(.fetchDatabaseInfos(gid))

                case .toggleShowFullTitle:
                    state.showsFullTitle.toggle()
                    return .run(operation: { _ in hapticsClient.generateFeedback(.soft) })

                case .toggleShowUserRating:
                    state.showsUserRating.toggle()
                    return .run(operation: { _ in hapticsClient.generateFeedback(.soft) })

                case .setCommentContent(let content):
                    state.commentContent = content
                    return .none

                case .setPostCommentFocused(let isFocused):
                    state.postCommentFocused = isFocused
                    return .none

                case .updateRating(let value):
                    state.updateRating(value: value)
                    return .none

                case .confirmRating(let value):
                    state.updateRating(value: value)
                    return .merge(
                        .send(.rateGallery),
                        .run(operation: { _ in hapticsClient.generateFeedback(.soft) }),
                        .run { send in
                            try await Task.sleep(for: .seconds(1))
                            await send(.confirmRatingDone)
                        }
                    )

                case .confirmRatingDone:
                    state.showsUserRating = false
                    return .none

                case .syncGalleryTags:
                    return .run { [state] _ in
                        let result = await databaseClient.updateGalleryTags(
                            gid: state.gallery.id, tags: state.galleryTags
                        )
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist gallery tags.", context: [
                                "gid": state.gallery.id, "error": "\(error)"
                            ])
                        }
                    }

                case .syncGalleryDetail:
                    guard let detail = state.galleryDetail else { return .none }
                    return .run { _ in
                        let result = await databaseClient.cacheGalleryDetail(detail)
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist gallery detail.", context: [
                                "gid": detail.gid, "error": "\(error)"
                            ])
                        }
                    }

                case .syncGalleryPreviewURLs:
                    return .run { [state] _ in
                        let result = await databaseClient
                            .updatePreviewURLs(gid: state.gallery.id, previewURLs: state.galleryPreviewURLs)
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist detail preview URLs.", context: [
                                "gid": state.gallery.id, "error": "\(error)"
                            ])
                        }
                    }

                case .syncGalleryComments:
                    return .run { [state] _ in
                        let result = await databaseClient.updateComments(
                            gid: state.gallery.id, comments: state.galleryComments
                        )
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist gallery comments.", context: [
                                "gid": state.gallery.id, "error": "\(error)"
                            ])
                        }
                    }

                case .syncGreeting(let greeting):
                    return .run { _ in
                        let result = await databaseClient.updateGreeting(greeting)
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist greeting.", context: ["error": "\(error)"])
                        }
                    }

                case .syncPreviewConfig(let config):
                    return .run { [state] _ in
                        let result = await databaseClient.updatePreviewConfig(gid: state.gallery.id, config: config)
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist preview config.", context: [
                                "gid": state.gallery.id, "error": "\(error)"
                            ])
                        }
                    }

                case .saveGalleryHistory:
                    return .run { [state] _ in
                        let result = await databaseClient.updateLastOpenDate(gid: state.gallery.id)
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist gallery history.", context: [
                                "gid": state.gallery.id, "error": "\(error)"
                            ])
                        }
                    }

                case .updateReadingProgress(let progress):
                    return .run { [state] _ in
                        let result = await databaseClient.updateReadingProgress(
                            gid: state.gallery.id, progress: progress
                        )
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist detail reading progress.", context: [
                                "gid": state.gallery.id, "progress": progress, "error": "\(error)"
                            ])
                        }
                    }

                case .navigateReading(let progress):
                    // The reader reads its starting page back from the database, so hand the
                    // page over in state first and only present it once the write has landed.
                    state.readingState.setInitialReadingProgress(progress)
                    return .run { [galleryID = state.gallery.id] send in
                        let result = await databaseClient.updateReadingProgress(gid: galleryID, progress: progress)
                        if case .failure(let error) = result {
                            Logger.error("Failed to persist reading navigation progress.", context: [
                                "gid": galleryID, "progress": progress, "error": "\(error)"
                            ])
                        }
                        await send(.setNavigation(.reading))
                    }

                case .downloadGallery:
                    guard let detail = state.galleryDetail else { return .none }
                    state.hudConfig = .success(caption: L10n.Localizable.DownloadsView.Toast.queued)
                    state.route = .hud
                    return .run { [gallery = state.gallery, previewConfig = state.previewConfig] _ in
                        await DownloadManager.shared.start(
                            gallery: gallery,
                            detail: detail,
                            previewConfig: previewConfig
                        )
                    }

                case .teardown:
                    return teardownEffect(instanceID: state.instanceID)

                case .fetchDatabaseInfos(let gid):
                    guard gid.isValidGID else {
                        state.loadingState = .failed(.notFound)
                        return .none
                    }
                    guard let gallery = databaseClient.fetchGallery(gid: gid) else {
                        // The list that navigated here may still be writing its results on a
                        // background context, so a miss is not final yet. Keep waiting for a
                        // short while, then fail visibly instead of staying blank forever.
                        state.loadingState = .loading
                        return .run { send in
                            for _ in 0..<Self.galleryCacheRetryCount {
                                try await Task.sleep(for: .milliseconds(Self.galleryCacheRetryInterval))
                                let isCached = await MainActor.run {
                                    databaseClient.fetchGallery(gid: gid) != nil
                                }
                                if isCached {
                                    await send(.fetchDatabaseInfos(gid))
                                    return
                                }
                            }
                            await send(.fetchDatabaseInfosFailed(gid))
                        }
                        .cancellable(
                            id: CancelID(instanceID: state.instanceID, identifier: .fetchDatabaseInfos),
                            cancelInFlight: true
                        )
                    }
                    state.gallery = gallery
                    state.loadingState = .idle
                    if let detail = databaseClient.fetchGalleryDetail(gid: gid) {
                        state.galleryDetail = detail
                        state.userRating = State.halfStars(from: detail.userRating)
                    }
                    return .merge(
                        .send(.saveGalleryHistory),
                        .run { [galleryID = state.gallery.id] send in
                            guard let dbState = await databaseClient.fetchGalleryState(gid: galleryID) else { return }
                            await send(.fetchDatabaseInfosDone(dbState))
                        }
                        .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .fetchDatabaseInfos))
                    )

                case .fetchDatabaseInfosFailed(let gid):
                    guard state.gallery.id == gid || !state.gallery.id.isValidGID else { return .none }
                    state.loadingState = .failed(.databaseUnavailable(nil))
                    return .none

                case .fetchDatabaseInfosDone(let galleryState):
                    guard galleryState.gid == state.gallery.id else { return .none }
                    state.galleryTags = galleryState.tags
                    state.galleryPreviewURLs = galleryState.previewURLs
                    state.galleryComments = galleryState.comments
                    if let config = galleryState.previewConfig {
                        state.previewConfig = config
                    }
                    return .send(.fetchGalleryDetail)

                case .fetchGalleryDetail:
                    guard state.loadingState != .loading,
                          let galleryURL = state.gallery.galleryURL
                    else { return .none }
                    state.loadingState = .loading
                    return .run { [galleryID = state.gallery.id] send in
                        let response = await GalleryDetailRequest(gid: galleryID, galleryURL: galleryURL).response()
                        await send(.fetchGalleryDetailDone(galleryID, response))
                    }
                    // Reappearing (or refreshing after a mutation) replaces the pending request
                    // instead of racing a second identical one against it.
                    .cancellable(
                        id: CancelID(instanceID: state.instanceID, identifier: .fetchGalleryDetail),
                        cancelInFlight: true
                    )

                case .fetchGalleryDetailDone(let gid, let result):
                    // A replaced detail must never accept the previous gallery's response.
                    guard gid == state.gallery.id else { return .none }
                    state.loadingState = .idle
                    switch result {
                    case .success(let (galleryDetail, galleryState, apiKey, greeting)):
                        var effects: [Effect<Action>] = [
                            .send(.syncGalleryTags),
                            .send(.syncGalleryDetail),
                            .send(.syncGalleryPreviewURLs),
                            .send(.syncGalleryComments)
                        ]
                        state.apiKey = apiKey
                        state.galleryDetail = galleryDetail
                        state.galleryTags = galleryState.tags
                        state.galleryPreviewURLs = galleryState.previewURLs
                        state.galleryComments = galleryState.comments
                        state.userRating = State.halfStars(from: galleryDetail.userRating)
                        if let greeting = greeting {
                            effects.append(.send(.syncGreeting(greeting)))
                            if !greeting.gainedNothing && state.showsNewDawnGreeting {
                                effects.append(.send(.setNavigation(.newDawn(greeting))))
                            }
                        }
                        if let config = galleryState.previewConfig {
                            state.previewConfig = config
                            effects.append(.send(.syncPreviewConfig(config)))
                        }
                        return .merge(effects)
                    case .failure(let error):
                        state.loadingState = .failed(error)
                    }
                    return .none

                case .rateGallery:
                    // Without an API key the request is guaranteed invalid, so do not send it.
                    guard state.isAPIReady, let apiuid = Int(cookieClient.apiuid),
                          let gid = Int(state.gallery.id)
                    else { return .none }
                    return .run { [state] send in
                        let response = await RateGalleryRequest(
                            apiuid: apiuid,
                            apikey: state.apiKey,
                            gid: gid,
                            token: state.gallery.token,
                            rating: state.userRating
                        )
                        .response()
                        await send(.anyGalleryOpsDone(response))
                    }
                    .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .rateGallery))

                case .favorGallery(let favIndex):
                    return .run { [state] send in
                        let response = await FavorGalleryRequest(
                            gid: state.gallery.id,
                            token: state.gallery.token,
                            favIndex: favIndex
                        )
                        .response()
                        await send(.anyGalleryOpsDone(response))
                    }
                    .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .favorGallery))

                case .unfavorGallery:
                    return .run { [galleryID = state.gallery.id] send in
                        let response = await UnfavorGalleryRequest(gid: galleryID).response()
                        await send(.anyGalleryOpsDone(response))
                    }
                    .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .unfavorGallery))

                case .postComment(let galleryURL):
                    guard !state.commentContent.isEmpty,
                          state.postCommentLoadingState != .loading
                    else { return .none }
                    state.postCommentLoadingState = .loading
                    return .run { [commentContent = state.commentContent] send in
                        let response = await CommentGalleryRequest(
                            content: commentContent, galleryURL: galleryURL
                        )
                        .response()
                        await send(.postCommentDone(response))
                    }
                    .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .postComment))

                case .postCommentDone(let result):
                    switch result {
                    case .success:
                        // The draft is only thrown away once the server confirmed the post, and
                        // never when the sheet was already dismissed and retyped in between.
                        if state.postCommentLoadingState == .loading {
                            state.postCommentLoadingState = .idle
                            state.commentContent = .init()
                            state.postCommentFocused = false
                            state.route = nil
                        }
                        return .merge(
                            .send(.fetchGalleryDetail),
                            .run(operation: { _ in hapticsClient.generateNotificationFeedback(.success) })
                        )
                    case .failure(let error):
                        // Keep the sheet and the draft, and show why it failed.
                        guard state.postCommentLoadingState == .loading else { return .none }
                        state.postCommentLoadingState = .failed(error)
                        return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })
                    }

                case .voteTag(let tag, let vote):
                    guard state.isAPIReady, let apiuid = Int(cookieClient.apiuid),
                          let gid = Int(state.gallery.id)
                    else { return .none }
                    return .run { [state] send in
                        let response = await VoteGalleryTagRequest(
                            apiuid: apiuid,
                            apikey: state.apiKey,
                            gid: gid,
                            token: state.gallery.token,
                            tag: tag,
                            vote: vote
                        )
                        .response()
                        await send(.anyGalleryOpsDone(response))
                    }
                    .cancellable(id: CancelID(instanceID: state.instanceID, identifier: .voteTag))

                case .anyGalleryOpsDone(let result):
                    switch result {
                    case .success:
                        return .merge(
                            .send(.fetchGalleryDetail),
                            .run(operation: { _ in hapticsClient.generateNotificationFeedback(.success) })
                        )
                    case .failure(let error):
                        // Server-side rejections are real failures now, so say so instead of
                        // only playing an error haptic.
                        state.hudConfig = .error(caption: error.alertText)
                        state.route = .hud
                        return .run(operation: { _ in hapticsClient.generateNotificationFeedback(.error) })
                    }

                case .reading(.onPerformDismiss):
                    return .send(.setNavigation(nil))

                case .reading:
                    return .none

                case .archives:
                    return .none

                case .torrents:
                    return .none

                case .previews:
                    return .none

                case .comments(.postCommentDone(let result)), .comments(.voteCommentDone(let result)):
                    // The comments screen owns its own failure presentation; refresh the
                    // detail only when the action actually succeeded.
                    guard case .success = result else { return .none }
                    return .send(.fetchGalleryDetail)

                case .comments(.detail(let recursiveAction)):
                    guard state.commentsState != nil else { return .none }
                    return self.reduce(into: &state.commentsState!.detailState, action: recursiveAction)
                        .map({ Action.comments(.detail($0)) })

                case .comments:
                    return .none

                case .galleryInfos:
                    return .none

                case .detailSearch(.detail(let recursiveAction)):
                    guard state.detailSearchState != nil else { return .none }
                    return self.reduce(into: &state.detailSearchState!.detailState, action: recursiveAction)
                        .map({ Action.detailSearch(.detail($0)) })

                case .detailSearch:
                    return .none
                }
            }
            .ifLet(
                \.commentsState,
                action: /Action.comments,
                then: CommentsReducer.init
            )
            .ifLet(
                \.detailSearchState,
                action: /Action.detailSearch,
                then: DetailSearchReducer.init
            )
            .haptics(
                unwrapping: \.route,
                case: /Route.detailSearch,
                hapticsClient: hapticsClient,
                style: .soft
            )
            .haptics(
                unwrapping: \.route,
                case: /Route.postComment,
                hapticsClient: hapticsClient
            )
            .haptics(
                unwrapping: \.route,
                case: /Route.tagDetail,
                hapticsClient: hapticsClient
            )
            .haptics(
                unwrapping: \.route,
                case: /Route.torrents,
                hapticsClient: hapticsClient
            )
            .haptics(
                unwrapping: \.route,
                case: /Route.archives,
                hapticsClient: hapticsClient
            )
            .haptics(
                unwrapping: \.route,
                case: /Route.reading,
                hapticsClient: hapticsClient
            )
            .haptics(
                unwrapping: \.route,
                case: /Route.share,
                hapticsClient: hapticsClient
            )

            Scope(state: \.readingState, action: /Action.reading, child: ReadingReducer.init)
            Scope(state: \.archivesState, action: /Action.archives, child: ArchivesReducer.init)
            Scope(state: \.torrentsState, action: /Action.torrents, child: TorrentsReducer.init)
            Scope(state: \.previewsState, action: /Action.previews, child: PreviewsReducer.init)
            Scope(state: \.galleryInfosState, action: /Action.galleryInfos, child: GalleryInfosReducer.init)
        }
    }
}
