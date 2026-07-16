//
//  AppToast.swift
//  EhPanda
//

import SwiftUI

enum AppToastType: Hashable {
    case loading
    case success
    case warning
    case error
}

struct AppToastConfig: Hashable {
    var type: AppToastType = .loading
    var title: String?
    var caption: String?
    var shouldAutoHide = false
    var autoHideInterval: TimeInterval = 1.5

    static let error: Self = error(caption: nil)
    static let loading: Self = loading(title: L10n.Localizable.Hud.Title.loading)
    static let communicating: Self = loading(title: L10n.Localizable.Hud.Title.communicating)
    static let savedToPhotoLibrary: Self = success(caption: L10n.Localizable.Hud.Caption.savedToPhotoLibrary)
    static let copiedToClipboardSucceeded: Self = success(
        caption: L10n.Localizable.Hud.Caption.copiedToClipboard
    )

    static func loading(title: String? = nil) -> Self {
        .init(type: .loading, title: title)
    }

    static func error(caption: String? = nil) -> Self {
        autoHide(type: .error, title: L10n.Localizable.Hud.Title.error, caption: caption)
    }

    static func success(caption: String? = nil) -> Self {
        autoHide(type: .success, title: L10n.Localizable.Hud.Title.success, caption: caption)
    }

    static func autoHide(
        type: AppToastType,
        title: String? = nil,
        caption: String? = nil
    ) -> Self {
        .init(type: type, title: title, caption: caption, shouldAutoHide: true)
    }
}

struct AppToast: View {
    @Binding var isPresented: Bool
    let config: AppToastConfig

    var body: some View {
        VStack {
            Spacer()
            if isPresented {
                HStack(spacing: 12) {
                    icon
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = config.title {
                            Text(title).font(.subheadline.bold())
                        }
                        if let caption = config.caption {
                            Text(caption).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .lineLimit(2)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: config) {
                    guard config.shouldAutoHide else { return }
                    try? await Task.sleep(for: .seconds(config.autoHideInterval))
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                        isPresented = false
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isPresented)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var icon: some View {
        switch config.type {
        case .loading:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .error:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        }
    }
}
