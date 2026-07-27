//
//  PostCommentView.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/01/03.
//

import SwiftUI

struct PostCommentView: View {
    private let title: String
    @Binding private var content: String
    @Binding private var isFocused: Bool
    private let loadingState: LoadingState
    private let postAction: () -> Void
    private let cancelAction: () -> Void
    private let onAppearAction: () -> Void

    @FocusState private var isTextEditorFocused: Bool

    init(
        title: String,
        content: Binding<String>,
        isFocused: Binding<Bool>,
        loadingState: LoadingState = .idle,
        postAction: @escaping () -> Void,
        cancelAction: @escaping () -> Void,
        onAppearAction: @escaping () -> Void
    ) {
        self.title = title
        _content = content
        _isFocused = isFocused
        self.loadingState = loadingState
        self.postAction = postAction
        self.cancelAction = cancelAction
        self.onAppearAction = onAppearAction
    }

    private var isPosting: Bool {
        loadingState == .loading
    }
    private var error: AppError? {
        guard case .failed(let error) = loadingState else { return nil }
        return error
    }

    var body: some View {
        NavigationView {
            VStack {
                TextEditor(text: $content).focused($isTextEditorFocused).padding()
                    .disabled(isPosting)
                // A failed submission keeps the draft, so it has to explain itself here.
                if let error = error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error.alertText).font(.callout)
                    }
                    .foregroundStyle(.red).padding(.horizontal).padding(.bottom, 8)
                    .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Localizable.PostCommentView.Button.cancel, action: cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    ZStack {
                        ProgressView().opacity(isPosting ? 1 : 0)
                        Button(
                            L10n.Localizable.PostCommentView.Button.post,
                            action: postAction
                        )
                        .opacity(isPosting ? 0 : 1)
                    }
                    .disabled(content.isEmpty || isPosting)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(title)
        }
        .synchronize($isFocused, $isTextEditorFocused)
        .onAppear(perform: onAppearAction)
    }
}
