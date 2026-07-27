//
//  ReadingView.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/22.
//

import SwiftUI
import Kingfisher
import SwiftUIPager
import ComposableArchitecture

struct ReadingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Dependency(\.imageClient) private var imageClient

    let store: StoreOf<ReadingReducer>
    @ObservedObject private var viewStore: ViewStoreOf<ReadingReducer>
    private let gid: String
    @Binding private var setting: Setting
    private let blurRadius: Double
    private let onDismiss: (() -> Void)?

    @StateObject private var liveTextHandler = LiveTextHandler()
    @StateObject private var autoPlayHandler = AutoPlayHandler()
    @StateObject private var gestureHandler = GestureHandler()
    @StateObject private var pageHandler = PageHandler()
    @StateObject private var page: Page = .first()
    @State private var didInitializePage = false
    @State private var isLandscape = DeviceUtil.isLandscape
    @State private var dismissState = DismissState()

    // Reference storage so the exactly-once guard also holds across `onDisappear`,
    // which runs after the view has already been removed.
    private final class DismissState {
        var didDismiss = false
    }

    init(
        store: StoreOf<ReadingReducer>,
        gid: String, setting: Binding<Setting>, blurRadius: Double,
        onDismiss: (() -> Void)? = nil
    ) {
        self.store = store
        viewStore = ViewStore(store, observe: { $0 })
        self.gid = gid
        _setting = setting
        self.blurRadius = blurRadius
        self.onDismiss = onDismiss
    }

    private var backgroundColor: Color {
        colorScheme == .light ? Color(.systemGray4) : Color(.systemGray6)
    }

    // Everything that replaces the pager's container. `Page.index` addresses that
    // container, so a change here invalidates it and requires an explicit remap.
    private var layoutKey: ReadingLayoutKey {
        .init(setting: setting, isLandscape: isLandscape)
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            ZStack {
                if !didInitializePage {
                    ProgressView()
                } else if setting.readingDirection == .vertical {
                    AdvancedList(
                        page: page,
                        data: viewStore.state.containerDataSource(setting: setting, isLandscape: isLandscape),
                        id: \.self, spacing: setting.contentDividerHeight,
                        gesture: SimultaneousGesture(magnificationGesture, tapGesture),
                        content: imageStack
                    )
                    .scrollDisabled(gestureHandler.scale != 1)
                } else {
                    Pager(
                        page: page,
                        data: viewStore.state.containerDataSource(setting: setting, isLandscape: isLandscape),
                        id: \.self, content: imageStack
                    )
                    .horizontal(setting.readingDirection == .rightToLeft ? .endToStart : .startToEnd)
                    .swipeInteractionArea(.allAvailable).allowsDragging(gestureHandler.scale == 1)
                }
            }
            .scaleEffect(gestureHandler.scale, anchor: gestureHandler.scaleAnchor)
            .offset(gestureHandler.offset)
            // iOS 16-compatible equivalent of gesture(_:isEnabled:) from 2.7.9/2.7.10
            .highPriorityGesture(
                dragGesture.simultaneously(with: tapGesture),
                including: gestureHandler.scale > 1 ? .all : .none
            )
            .gesture(tapGesture, including: gestureHandler.scale == 1 ? .all : .none)
            .gesture(magnificationGesture)
            .ignoresSafeArea()
            ControlPanel(
                showsPanel: viewStore.$showsPanel,
                showsSliderPreview: viewStore.$showsSliderPreview,
                sliderValue: $pageHandler.sliderValue, setting: $setting,
                enablesLiveText: $liveTextHandler.enablesLiveText,
                autoPlayPolicy: .init(get: { autoPlayHandler.policy }, set: setAutoPlayPolocy),
                range: 1...Float(viewStore.state.validPageCount), previewURLs: viewStore.previewURLs,
                dismissGesture: controlPanelDismissGesture,
                dismissAction: performDismiss,
                navigateSettingAction: { viewStore.send(.setNavigation(.readingSetting)) },
                reloadAllImagesAction: { viewStore.send(.reloadAllWebImages) },
                retryAllFailedImagesAction: { viewStore.send(.retryAllFailedWebImages) },
                fetchPreviewURLsAction: { viewStore.send(.fetchPreviewURLs($0)) }
            )
        }
        .sheet(unwrapping: viewStore.$route, case: /ReadingReducer.Route.readingSetting) { _ in
            NavigationView {
                ReadingSettingView(
                    readingDirection: $setting.readingDirection,
                    prefetchLimit: $setting.prefetchLimit,
                    enablesLandscape: $setting.enablesLandscape,
                    contentDividerHeight: $setting.contentDividerHeight,
                    maximumScaleFactor: $setting.maximumScaleFactor,
                    doubleTapScaleFactor: $setting.doubleTapScaleFactor
                )
                .toolbar {
                    if !DeviceUtil.isPad && DeviceUtil.isLandscape {
                        CustomToolbarItem(placement: .cancellationAction) {
                            Button {
                                viewStore.send(.setNavigation(nil))
                            } label: {
                                Image(systemSymbol: .chevronDown)
                            }
                        }
                    }
                }
            }
            .accentColor(setting.accentColor).tint(setting.accentColor)
            .autoBlur(radius: blurRadius).navigationViewStyle(.stack)
        }
        .sheet(unwrapping: viewStore.$route, case: /ReadingReducer.Route.share) { route in
            ActivityView(activityItems: [route.wrappedValue.associatedValue])
                .accentColor(setting.accentColor).autoBlur(radius: blurRadius)
        }
        .progressHUD(
            config: viewStore.hudConfig,
            unwrapping: viewStore.$route,
            case: /ReadingReducer.Route.hud
        )

        // Page
        .onChange(of: page.index) { pageIndex in
            Logger.info("page.index changed", context: ["pageIndex": pageIndex])
            // A layout remap replaces the container underneath the pager. Both the index
            // the remap writes and any index SwiftUIPager clamps out of the replaced data
            // source before the remap runs describe the transition, not the reader, so
            // neither may be persisted. The second case is recognized by the index
            // arriving while the reconciled layout is still the previous one, which also
            // makes the remap self-healing if the two observers fire out of order.
            guard !pageHandler.consumeLayoutRemap() else { return }
            guard pageHandler.matchesReconciledLayout(layoutKey) else {
                remapPageForLayoutChange()
                return
            }
            let pageCount = viewStore.state.validPageCount
            let mapped = pageHandler.mapFromPager(
                index: pageIndex, pageCount: pageCount,
                setting: setting, isLandscape: isLandscape
            )
            let progress = min(max(mapped, 1), pageCount)
            pageHandler.setPhysicalPage(progress)
            pageHandler.sliderValue = .init(progress)
            if didInitializePage, viewStore.databaseLoadingState == .idle {
                viewStore.send(.syncReadingProgress(progress))
            }
        }
        .onChange(of: layoutKey) { _ in
            remapPageForLayoutChange()
        }
        .onChange(of: pageHandler.sliderValue) { sliderValue in
            Logger.info("pageHandler.sliderValue changed", context: ["sliderValue": sliderValue])
            if !viewStore.showsSliderPreview {
                setPageIndex(sliderValue: sliderValue)
            }
        }
        .onChange(of: viewStore.showsSliderPreview) { isShown in
            Logger.info("viewStore.showsSliderPreview changed", context: ["isShown": isShown])
            if !isShown { setPageIndex(sliderValue: pageHandler.sliderValue) }
            setAutoPlayPolocy(.off)
        }
        .onChange(of: viewStore.readingProgress) { readingProgress in
            Logger.info("viewStore.readingProgress changed", context: ["readingProgress": readingProgress])
            initializePageIfReady()
        }
        .onChange(of: viewStore.databaseLoadingState) { _ in
            initializePageIfReady()
        }

        // AutoPlay
        .onChange(of: viewStore.route) { route in
            Logger.info("viewStore.route changed", context: ["route": route])
            if ![.hud, .none].contains(route) {
                setAutoPlayPolocy(.off)
            }
        }

        // LiveText
        .onChange(of: liveTextHandler.enablesLiveText) { isEnabled in
            Logger.info("liveTextHandler.enablesLiveText changed", context: ["isEnabled": isEnabled])
            if isEnabled {
                liveTextHandler.startEnabledGeneration()
                scheduleLiveTextAnalyses(indices: viewStore.webImageLoadSuccessIndices)
            } else {
                // Switching the feature off has to stop the work, not just hide it: an
                // unretained image fetch used to survive and enqueue a fresh Vision
                // request into a reader that no longer shows any of it.
                liveTextHandler.cancelRequests()
            }
        }
        .onChange(of: viewStore.webImageLoadSuccessIndices) { indices in
            Logger.info("viewStore.webImageLoadSuccessIndices changed", context: [
                "count": indices.count
            ])
            scheduleLiveTextAnalyses(indices: indices)
        }

        // Orientation
        .onChange(of: setting.enablesLandscape) { newValue in
            Logger.info("setting.enablesLandscape changed", context: ["newValue": newValue])
            viewStore.send(.setOrientationPortrait(!newValue))
        }

        // Interactive pinch/pan samples are excluded: animating each one makes the
        // transform chase the finger instead of following it.
        .animation(
            gestureHandler.isInteracting ? nil : Animation.linear(duration: 0.1),
            value: gestureHandler.offset
        )
        .animation(.default, value: liveTextHandler.enablesLiveText)
        .animation(.default, value: liveTextHandler.liveTextGroups)
        .animation(
            gestureHandler.isInteracting ? nil : Animation.default,
            value: gestureHandler.scale
        )
        .animation(.default, value: viewStore.showsPanel)
        .statusBar(hidden: !viewStore.showsPanel)

        // Orientation. The container layout depends on the interface orientation, which
        // has no observable source here, so a layout-neutral geometry probe drives it.
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { synchronizeOrientation() }
                    .onChange(of: geometry.size) { _ in synchronizeOrientation() }
            }
        )
        .onChange(of: scenePhase) { phase in
            guard phase != .active else { return }
            flushPendingPersistence()
        }
        .onDisappear {
            liveTextHandler.cancelRequests()
            setAutoPlayPolocy(.off)
            flushPendingPersistence()
            finishStandaloneDismiss()
        }
        .onAppear {
            viewStore.send(.onAppear(gid, setting.enablesLandscape))
            initializePageIfReady()
        }
    }

    @ViewBuilder private func imageStack(index: Int) -> some View {
        let imageStackConfig = viewStore.state.imageContainerConfigs(
            index: index, setting: setting, isLandscape: isLandscape
        )
        let isDualPage = setting.enablesDualPageMode && setting.readingDirection != .vertical && isLandscape
        let dataSource = viewStore.state.containerDataSource(setting: setting, isLandscape: isLandscape)
        let activeStackIndex = dataSource.indices.contains(page.index) ? dataSource[page.index] : nil
        HorizontalImageStack(
            index: index, isDualPage: isDualPage, isActive: index == activeStackIndex,
            isDatabaseLoading: viewStore.databaseLoadingState != .idle,
            backgroundColor: backgroundColor, config: imageStackConfig, imageURLs: viewStore.imageURLs,
            originalImageURLs: viewStore.originalImageURLs, loadingStates: viewStore.imageURLLoadingStates,
            enablesLiveText: liveTextHandler.enablesLiveText, liveTextGroups: liveTextHandler.liveTextGroups,
            focusedLiveTextGroup: liveTextHandler.focusedLiveTextGroup,
            liveTextTapAction: liveTextHandler.setFocusedLiveTextGroup,
            fetchAction: { viewStore.send(.fetchImageURLs($0)) },
            refetchAction: { viewStore.send(.refetchImageURLs($0)) },
            prefetchAction: { viewStore.send(.prefetchImages($0, setting.prefetchLimit)) },
            loadRetryAction: { viewStore.send(.onWebImageRetry($0)) },
            loadSucceededAction: { viewStore.send(.onWebImageSucceeded($0)) },
            loadFailedAction: { viewStore.send(.onWebImageFailed($0)) },
            copyImageAction: { viewStore.send(.copyImage($0)) },
            saveImageAction: { viewStore.send(.saveImage($0)) },
            shareImageAction: { viewStore.send(.shareImage($0)) }
        )
    }
}

// MARK: Handler methods
extension ReadingView {
    func initializePageIfReady() {
        guard !didInitializePage, viewStore.databaseLoadingState == .idle else { return }
        let pageCount = viewStore.state.validPageCount
        let readingProgress = min(max(viewStore.readingProgress, 1), pageCount)
        pageHandler.setPhysicalPage(readingProgress)
        pageHandler.setReconciledLayout(layoutKey)
        pageHandler.sliderValue = Float(readingProgress)
        let pageIndex = pageHandler.mapToPager(
            index: readingProgress, setting: setting, isLandscape: isLandscape
        )
        page.update(.new(index: max(0, pageIndex)))
        didInitializePage = true
    }

    func setPageIndex(sliderValue: Float) {
        let newValue = pageHandler.mapToPager(
            index: .init(sliderValue), setting: setting, isLandscape: isLandscape
        )
        if page.index != newValue {
            page.update(.new(index: newValue))
            Logger.info("Pager.update", context: ["update": newValue])
        }
    }

    private func synchronizeOrientation() {
        let newValue = DeviceUtil.isLandscape
        guard isLandscape != newValue else { return }
        isLandscape = newValue
    }

    // Orientation, reading direction, dual-page and except-cover all replace the
    // container. Map the canonical physical page into the new container in one step so
    // a stale container index can neither jump the reader nor be persisted as progress.
    private func remapPageForLayoutChange() {
        guard didInitializePage else { return }
        let pageCount = viewStore.state.validPageCount
        let physicalPage = min(max(pageHandler.physicalPage, 1), pageCount)
        let dataSource = viewStore.state.containerDataSource(setting: setting, isLandscape: isLandscape)
        let mapped = pageHandler.mapToPager(
            index: physicalPage, setting: setting, isLandscape: isLandscape
        )
        let target = min(max(mapped, 0), max(0, dataSource.count - 1))
        pageHandler.setReconciledLayout(layoutKey)
        pageHandler.sliderValue = Float(physicalPage)
        guard page.index != target else { return }
        pageHandler.beginLayoutRemap()
        page.update(.new(index: target))
        Logger.info("Pager.update", context: ["update": target])
    }

    // The standalone (offline) host has no parent reducer intercepting
    // `.onPerformDismiss`, so the reader owns its own exit: full teardown first, then
    // the host callback, exactly once regardless of which affordance triggered it.
    private func performDismiss() {
        // Persistence is coalesced, and online hosts reset the reading state before the
        // teardown they send is reduced, so the flush has to happen while the state is
        // still the one being read.
        flushPendingPersistence()
        viewStore.send(.onPerformDismiss)
        finishStandaloneDismiss()
    }

    private func flushPendingPersistence() {
        viewStore.send(.commitReadingProgress)
        viewStore.send(.commitURLCheckpoint)
    }

    private func finishStandaloneDismiss() {
        guard let onDismiss, !dismissState.didDismiss else { return }
        dismissState.didDismiss = true
        viewStore.send(.teardown)
        onDismiss()
    }

    func setAutoPlayPolocy(_ policy: AutoPlayPolicy) {
        autoPlayHandler.setPolicy(policy, updatePageAction: advancePageForAutoPlay)
    }

    // Vertical reading never gives SwiftUIPager a page count, so `.next` kept advancing
    // past the end and showed and saved impossible progress. Bound against the real
    // container instead and stop at the last page.
    private func advancePageForAutoPlay() {
        let dataSource = viewStore.state.containerDataSource(setting: setting, isLandscape: isLandscape)
        let newValue = page.index + 1
        guard newValue <= dataSource.count - 1 else {
            setAutoPlayPolocy(.off)
            return
        }
        page.update(.new(index: newValue))
        Logger.info("Pager.update", context: ["update": newValue])
    }

    // OCR is scheduled, never fired per notification. The loaded-page set changes on
    // every image, so starting a request for each change re-walked the whole set and
    // restarted pages that had not finished yet. The handler deduplicates across its
    // queued/running/finished states, runs a couple of pages at a time nearest the
    // reader first, and drops anything that finishes after a cancellation.
    //
    // Everything the background stages need is snapshotted here, on the main thread, so
    // no view or store state is read after a suspension point.
    func scheduleLiveTextAnalyses(indices: Set<Int>) {
        guard liveTextHandler.enablesLiveText else { return }
        let client = imageClient
        liveTextHandler.scheduleAnalyses(
            indices: indices,
            imageURLs: viewStore.imageURLs,
            priorityIndex: pageHandler.physicalPage,
            recognitionLanguages: viewStore.galleryDetail?.language.codes,
            imageProvider: { url in
                guard case .success(let image) = await client.fetchImage(url: url) else {
                    return nil
                }
                return image
            }
        )
    }
}

// MARK: Gesture
extension ReadingView {
    var tapGesture: some Gesture {
        let singleTap = TapGesture(count: 1)
            .onEnded {
                gestureHandler.onSingleTapGestureEnded(
                    readingDirection: setting.readingDirection,
                    setPageIndexOffsetAction: {
                        let newValue = page.index + $0
                        page.update(.new(index: newValue))
                        Logger.info("Pager.update", context: ["update": newValue])
                    },
                    toggleShowsPanelAction: { viewStore.send(.toggleShowsPanel) }
                )
            }
        let doubleTap = TapGesture(count: 2)
            .onEnded {
                gestureHandler.onDoubleTapGestureEnded(
                    scaleMaximum: setting.maximumScaleFactor,
                    doubleTapScale: setting.doubleTapScaleFactor
                )
            }
        return ExclusiveGesture(doubleTap, singleTap)
    }
    var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged {
                gestureHandler.onMagnificationGestureChanged(
                    value: $0, scaleMaximum: setting.maximumScaleFactor
                )
            }
            .onEnded {
                gestureHandler.onMagnificationGestureEnded(
                    value: $0, scaleMaximum: setting.maximumScaleFactor
                )
            }
    }
    var dragGesture: some Gesture {
        DragGesture(minimumDistance: .zero, coordinateSpace: .local)
            .onChanged(gestureHandler.onDragGestureChanged)
            .onEnded(gestureHandler.onDragGestureEnded)
    }
    var controlPanelDismissGesture: some Gesture {
        DragGesture().onEnded {
            gestureHandler.onControlPanelDismissGestureEnded(
                value: $0, dismissAction: performDismiss
            )
        }
    }
}

// MARK: HorizontalImageStack
private struct HorizontalImageStack: View {
    private let index: Int
    private let isDualPage: Bool
    private let isActive: Bool
    private let isDatabaseLoading: Bool
    private let backgroundColor: Color
    private let config: ImageStackConfig
    private let imageURLs: [Int: URL]
    private let originalImageURLs: [Int: URL]
    private let loadingStates: [Int: LoadingState]
    private let enablesLiveText: Bool
    private let liveTextGroups: [Int: [LiveTextGroup]]
    private let focusedLiveTextGroup: LiveTextGroup?
    private let liveTextTapAction: (LiveTextGroup) -> Void
    private let fetchAction: (Int) -> Void
    private let refetchAction: (Int) -> Void
    private let prefetchAction: (Int) -> Void
    private let loadRetryAction: (Int) -> Void
    private let loadSucceededAction: (Int) -> Void
    private let loadFailedAction: (Int) -> Void
    private let copyImageAction: (URL) -> Void
    private let saveImageAction: (URL) -> Void
    private let shareImageAction: (URL) -> Void

    init(
        index: Int, isDualPage: Bool, isActive: Bool, isDatabaseLoading: Bool, backgroundColor: Color,
        config: ImageStackConfig, imageURLs: [Int: URL], originalImageURLs: [Int: URL],
        loadingStates: [Int: LoadingState], enablesLiveText: Bool,
        liveTextGroups: [Int: [LiveTextGroup]], focusedLiveTextGroup: LiveTextGroup?,
        liveTextTapAction: @escaping (LiveTextGroup) -> Void,
        fetchAction: @escaping (Int) -> Void,
        refetchAction: @escaping (Int) -> Void, prefetchAction: @escaping (Int) -> Void,
        loadRetryAction: @escaping (Int) -> Void, loadSucceededAction: @escaping (Int) -> Void,
        loadFailedAction: @escaping (Int) -> Void, copyImageAction: @escaping (URL) -> Void,
        saveImageAction: @escaping (URL) -> Void, shareImageAction: @escaping (URL) -> Void
    ) {
        self.index = index
        self.isDualPage = isDualPage
        self.isActive = isActive
        self.isDatabaseLoading = isDatabaseLoading
        self.backgroundColor = backgroundColor
        self.config = config
        self.imageURLs = imageURLs
        self.originalImageURLs = originalImageURLs
        self.loadingStates = loadingStates
        self.enablesLiveText = enablesLiveText
        self.liveTextGroups = liveTextGroups
        self.focusedLiveTextGroup = focusedLiveTextGroup
        self.liveTextTapAction = liveTextTapAction
        self.fetchAction = fetchAction
        self.refetchAction = refetchAction
        self.prefetchAction = prefetchAction
        self.loadRetryAction = loadRetryAction
        self.loadSucceededAction = loadSucceededAction
        self.loadFailedAction = loadFailedAction
        self.copyImageAction = copyImageAction
        self.saveImageAction = saveImageAction
        self.shareImageAction = shareImageAction
    }

    var body: some View {
        HStack(spacing: 0) {
            if config.isFirstAvailable {
                imageContainer(index: config.firstIndex)
            }
            if config.isSecondAvailable {
                imageContainer(index: config.secondIndex)
            }
        }
    }

    func imageContainer(index: Int) -> some View {
        ImageContainer(
            index: index,
            imageURL: imageURLs[index],
            loadingState: loadingStates[index] ?? .idle,
            isDualPage: isDualPage,
            backgroundColor: backgroundColor,
            enablesLiveText: enablesLiveText,
            liveTextGroups: liveTextGroups[index] ?? [],
            focusedLiveTextGroup: focusedLiveTextGroup,
            liveTextTapAction: liveTextTapAction,
            refetchAction: refetchAction,
            loadRetryAction: loadRetryAction,
            loadSucceededAction: loadSucceededAction,
            loadFailedAction: loadFailedAction
        )
        .onAppear {
            activate(index: index)
        }
        .onChange(of: isActive) { isActive in
            if isActive { activate(index: index) }
        }
        .onChange(of: isDatabaseLoading) { isLoading in
            if !isLoading { activate(index: index) }
        }
        .onChange(of: imageURLs[index]) { imageURL in
            if imageURL == nil { activate(index: index) }
        }
        .contextMenu { contextMenuItems(index: index) }
    }
    private func activate(index: Int) {
        guard isActive, !isDatabaseLoading else { return }
        if imageURLs[index] == nil {
            fetchAction(index)
        }
        prefetchAction(index)
    }
    @ViewBuilder private func contextMenuItems(index: Int) -> some View {
        Button {
            refetchAction(index)
        } label: {
            Label(L10n.Localizable.ReadingView.ContextMenu.Button.reload, systemSymbol: .arrowCounterclockwise)
        }
        if let imageURL = imageURLs[index] {
            Button {
                copyImageAction(imageURL)
            } label: {
                Label(L10n.Localizable.ReadingView.ContextMenu.Button.copy, systemSymbol: .plusSquareOnSquare)
            }
            Button {
                saveImageAction(imageURL)
            } label: {
                Label(L10n.Localizable.ReadingView.ContextMenu.Button.save, systemSymbol: .squareAndArrowDown)
            }
            if let originalImageURL = originalImageURLs[index] {
                Button {
                    saveImageAction(originalImageURL)
                } label: {
                    Label(
                        L10n.Localizable.ReadingView.ContextMenu.Button.saveOriginal,
                        systemSymbol: .squareAndArrowDownOnSquare
                    )
                }
            }
            Button {
                shareImageAction(imageURL)
            } label: {
                Label(L10n.Localizable.ReadingView.ContextMenu.Button.share, systemSymbol: .squareAndArrowUp)
            }
        }
    }
}

// MARK: ImageContainer
private struct ImageContainer: View {
    private var width: CGFloat {
        DeviceUtil.windowW / (isDualPage ? 2 : 1)
    }
    private var height: CGFloat {
        width / (imageURL?.readerImageAspectRatio ?? Defaults.ImageSize.contentAspect)
    }

    private let index: Int
    private let imageURL: URL?
    private let loadingState: LoadingState
    private let isDualPage: Bool
    private let backgroundColor: Color
    private let enablesLiveText: Bool
    private let liveTextGroups: [LiveTextGroup]
    private let focusedLiveTextGroup: LiveTextGroup?
    private let liveTextTapAction: (LiveTextGroup) -> Void
    private let refetchAction: (Int) -> Void
    private let loadRetryAction: (Int) -> Void
    private let loadSucceededAction: (Int) -> Void
    private let loadFailedAction: (Int) -> Void

    init(
        index: Int, imageURL: URL?,
        loadingState: LoadingState,
        isDualPage: Bool,
        backgroundColor: Color,
        enablesLiveText: Bool,
        liveTextGroups: [LiveTextGroup],
        focusedLiveTextGroup: LiveTextGroup?,
        liveTextTapAction: @escaping (LiveTextGroup) -> Void,
        refetchAction: @escaping (Int) -> Void,
        loadRetryAction: @escaping (Int) -> Void,
        loadSucceededAction: @escaping (Int) -> Void,
        loadFailedAction: @escaping (Int) -> Void
    ) {
        self.index = index
        self.imageURL = imageURL
        self.loadingState = loadingState
        self.isDualPage = isDualPage
        self.backgroundColor = backgroundColor
        self.enablesLiveText = enablesLiveText
        self.liveTextGroups = liveTextGroups
        self.focusedLiveTextGroup = focusedLiveTextGroup
        self.liveTextTapAction = liveTextTapAction
        self.refetchAction = refetchAction
        self.loadRetryAction = loadRetryAction
        self.loadSucceededAction = loadSucceededAction
        self.loadFailedAction = loadFailedAction
    }

    private func placeholder(_ progress: Progress) -> some View {
        Placeholder(style: .progress(
            pageNumber: index, progress: progress,
            isDualPage: isDualPage, backgroundColor: backgroundColor
        ))
        .frame(width: width, height: height)
    }
    // Reader pages are cached under a keystamp/host-normalized key, so a refetched
    // H@H URL for the same page (new node or new signature) is a cache hit instead
    // of a full re-download.
    private func cacheKey(url: URL?) -> String? {
        guard let url else { return nil }
        return url.isFileURL ? url.path : (url.stableImageCacheKey ?? url.absoluteString)
    }

    @ViewBuilder private func image(url: URL?) -> some View {
        if url?.isAnimatedImage != true {
            KFImage.url(url, cacheKey: cacheKey(url: url))
                .cacheMemoryOnly(url?.isFileURL == true)
                .placeholder(placeholder)
                .defaultModifier(withRoundedCorners: false)
                .backgroundDecode()
                .retry(maxCount: 2, interval: .seconds(1))
                .onSuccess(onSuccess).onFailure(onFailure)
        } else {
            KFAnimatedImage(source: url.map {
                .network(KF.ImageResource(downloadURL: $0, cacheKey: cacheKey(url: $0)))
            })
            .cacheMemoryOnly(url?.isFileURL == true)
            .placeholder(placeholder).fade(duration: 0.25)
            .retry(maxCount: 2, interval: .seconds(1))
            .onSuccess(onSuccess).onFailure(onFailure)
        }
    }

    var body: some View {
        if loadingState == .idle {
            image(url: imageURL).scaledToFit().overlay(
                LiveTextView(
                    liveTextGroups: liveTextGroups,
                    focusedLiveTextGroup: focusedLiveTextGroup,
                    tapAction: liveTextTapAction
                )
                .opacity(enablesLiveText ? 1 : 0)
                // A hidden overlay is still a hit-testing overlay: without this the
                // recognized-text views kept taking touches from the pager and the zoom
                // surface while Live Text was switched off.
                .allowsHitTesting(enablesLiveText)
            )
        } else {
            ZStack {
                backgroundColor
                VStack {
                    Text(String(index)).font(.largeTitle.bold())
                        .foregroundColor(.gray).padding(.bottom, 30)
                    ZStack {
                        Button(action: reloadImage) {
                            Image(systemSymbol: .exclamationmarkArrowTriangle2Circlepath)
                        }
                        .font(.system(size: 30, weight: .medium)).foregroundColor(.gray)
                        .opacity(loadingState == .loading ? 0 : 1)
                        ProgressView().opacity(loadingState == .loading ? 1 : 0)
                    }
                }
            }
            .frame(width: width, height: height)
        }
    }
    private func reloadImage() {
        if let error = (/LoadingState.failed).extract(from: loadingState) {
            if case .webImageFailed = error {
                loadRetryAction(index)
            } else {
                refetchAction(index)
            }
        }
    }
    private func onSuccess(_: RetrieveImageResult) {
        loadSucceededAction(index)
    }
    private func onFailure(_ error: KingfisherError) {
        guard imageURL != nil else { return }
        // A cancelled or superseded task is not a load failure: it fires when the URL is
        // refreshed mid-flight or a cell is recycled, and marking it failed would burn
        // the automatic retry and strand the page on the error placeholder.
        guard !error.isTaskCancelled, !error.isNotCurrentTask else { return }
        Logger.error("Reader image failed", context: [
            "index": index,
            "host": imageURL?.host ?? "nil",
            "error": error.localizedDescription
        ])
        loadFailedAction(index)
    }
}

// MARK: Definition
struct ImageStackConfig {
    let firstIndex: Int
    let secondIndex: Int
    let isFirstAvailable: Bool
    let isSecondAvailable: Bool
}

enum AutoPlayPolicy: Int, CaseIterable, Identifiable {
    var id: Int { rawValue }

    case off = -1
    case sec1 = 1
    case sec2 = 2
    case sec3 = 3
    case sec4 = 4
    case sec5 = 5
}

extension AutoPlayPolicy {
    var value: String {
        switch self {
        case .off:
            return L10n.Localizable.Enum.AutoPlayPolicy.Value.off
        default:
            return L10n.Localizable.Common.Value.seconds("\(rawValue)")
        }
    }
}

struct ReadingView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            Text("")
                .fullScreenCover(isPresented: .constant(true)) {
                    ReadingView(
                        store: .init(initialState: .init(gallery: .empty), reducer: ReadingReducer.init),
                        gid: .init(),
                        setting: .constant(.init()),
                        blurRadius: 0
                    )
                }
        }
    }
}
