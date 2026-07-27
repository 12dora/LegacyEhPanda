//
//  PreviewsView.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/10.
//

import SwiftUI
import Kingfisher
import ComposableArchitecture

struct PreviewsView: View {
    private let store: StoreOf<PreviewsReducer>
    @ObservedObject private var viewStore: ViewStoreOf<PreviewsReducer>
    private let gid: String
    @Binding private var setting: Setting
    private let blurRadius: Double

    init(
        store: StoreOf<PreviewsReducer>,
        gid: String, setting: Binding<Setting>, blurRadius: Double
    ) {
        self.store = store
        viewStore = ViewStore(store, observe: { $0 })
        self.gid = gid
        _setting = setting
        self.blurRadius = blurRadius
    }

    private var gridItems: [GridItem] {
        [GridItem(
            .adaptive(
                minimum: Defaults.ImageSize.previewMinW,
                maximum: Defaults.ImageSize.previewMaxW
            ),
            spacing: 10
        )]
    }

    private var databaseError: AppError? {
        guard case .failed(let error) = viewStore.databaseLoadingState else { return nil }
        return error
    }
    private func previewLoadingState(at index: Int) -> LoadingState {
        viewStore.previewLoadingStates[index] ?? .idle
    }
    private func previewFailed(at index: Int) -> Bool {
        guard viewStore.previewURLs[index] == nil,
              case .failed = previewLoadingState(at: index)
        else { return false }
        return true
    }
    private func fetchPreviewURLsIfNeeded(at index: Int) {
        // Driven by the missing page, not by a batch boundary that a scroll may skip.
        guard viewStore.databaseLoadingState != .loading,
              viewStore.previewURLs[index] == nil
        else { return }
        if case .failed = previewLoadingState(at: index) { return }
        viewStore.send(.fetchPreviewURLs(index))
    }

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: gridItems) {
                    ForEach(1..<viewStore.gallery.pageCount + 1, id: \.self) { index in
                        VStack {
                            let (url, modifier) = PreviewResolver.getPreviewConfigs(
                                originalURL: viewStore.previewURLs[index]
                            )
                            ZStack {
                                Button {
                                    viewStore.send(.navigateReading(index))
                                } label: {
                                    KFImage.url(url, cacheKey: viewStore.previewURLs[index]?.absoluteString)
                                        .placeholder {
                                            Placeholder(style: .activity(ratio: Defaults.ImageSize.previewAspect))
                                        }
                                        .imageModifier(modifier).fade(duration: 0.25).resizable().scaledToFit()
                                }
                                // A failed batch used to stay a silent placeholder forever.
                                if previewFailed(at: index) {
                                    Button {
                                        viewStore.send(.fetchPreviewURLs(index))
                                    } label: {
                                        Image(systemSymbol: .exclamationmarkArrowTriangle2Circlepath)
                                            .foregroundStyle(.red).imageScale(.large)
                                    }
                                }
                            }
                            Text("\(index)").font(DeviceUtil.isPadWidth ? .callout : .caption)
                                .foregroundColor(.secondary)
                        }
                        .onAppear {
                            fetchPreviewURLsIfNeeded(at: index)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
                .id(viewStore.databaseLoadingState)
            }
            .opacity(databaseError == nil ? 1 : 0)
            if let error = databaseError {
                ErrorView(error: error) {
                    viewStore.send(.fetchDatabaseInfos(gid))
                }
            }
        }
        .fullScreenCover(unwrapping: viewStore.$route, case: /PreviewsReducer.Route.reading) { _ in
            ReadingView(
                store: store.scope(state: \.readingState, action: PreviewsReducer.Action.reading),
                gid: gid, setting: $setting, blurRadius: blurRadius
            )
            .accentColor(setting.accentColor)
            .autoBlur(radius: blurRadius)
        }
        .onAppear {
            viewStore.send(.fetchDatabaseInfos(gid))
        }
        .navigationTitle(L10n.Localizable.PreviewsView.Title.previews)
    }
}

struct PreviewsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            PreviewsView(
                store: .init(initialState: .init(gallery: .preview), reducer: PreviewsReducer.init),
                gid: .init(),
                setting: .constant(.init()),
                blurRadius: 0
            )
        }
    }
}
