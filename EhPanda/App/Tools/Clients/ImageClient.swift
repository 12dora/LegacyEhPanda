//
//  ImageClient.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/23.
//

import Photos
import SwiftUI
import Combine
import Kingfisher
import KingfisherWebP
import ComposableArchitecture

struct ImageClient {
    let prefetchImages: ([URL]) -> Void
    let saveImageToPhotoLibrary: (UIImage, Bool) async -> Bool
    let downloadImage: (URL) async -> Result<UIImage, Error>
    let retrieveImage: (String) async -> Result<UIImage, Error>
    let loadReaderImageAsset:
        (URL, (@MainActor (Double) -> Void)?) async -> Result<ReaderImageAsset, Error>
}

extension ImageClient {
    static let live: Self = .init(
        prefetchImages: { urls in
            Task { @MainActor in
                ReaderImagePrefetchCoordinator.shared.update(urls: urls)
            }
        },
        saveImageToPhotoLibrary: { (image, isAnimated) in
            await withCheckedContinuation { continuation in
                if let data = image.kf.data(format: isAnimated ? .GIF : .unknown) {
                    PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: .photo, data: data, options: nil)
                    } completionHandler: { (isSuccess, _) in
                        continuation.resume(returning: isSuccess)
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
        },
        downloadImage: { url in
            await withCheckedContinuation { continuation in
                KingfisherManager.shared.downloader.downloadImage(with: url, options: nil) { result in
                    switch result {
                    case .success(let result):
                        continuation.resume(returning: .success(result.image))
                    case .failure(let error):
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        },
        retrieveImage: { key in
            await withCheckedContinuation { continuation in
                // Reader images are stored with the WebP processor applied, which is part
                // of the effective cache key; omitting it here would always miss.
                KingfisherManager.shared.cache.retrieveImage(
                    forKey: key, options: [.processor(WebPProcessor.default)]
                ) { result in
                    switch result {
                    case .success(let result):
                        if let image = result.image {
                            continuation.resume(returning: .success(image))
                        } else {
                            continuation.resume(returning: .failure(AppError.notFound))
                        }
                    case .failure(let error):
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        },
        loadReaderImageAsset: { url, onProgress in
            do {
                return .success(try await ReaderImagePipeline.shared.asset(
                    for: url, priority: .userInitiated, onProgress: onProgress
                ))
            } catch {
                return .failure(error)
            }
        }
    )

    func fetchImage(url: URL) async -> Result<UIImage, Error> {
        if !url.isFileURL {
            for key in [url.stableImageCacheKey, url.absoluteString].compactMap({ $0 }) {
                if case .success(let image) = await retrieveImage(key) {
                    return .success(image)
                }
            }
        }
        switch await loadReaderImageAsset(url, nil) {
        case .success(let asset):
            return .success(asset.image)
        case .failure(let error):
            return .failure(error)
        }
    }

    func fetchReaderImage(
        url: URL,
        onProgress: (@MainActor (Double) -> Void)? = nil
    ) async -> Result<ReaderImageAsset, Error> {
        await loadReaderImageAsset(url, onProgress)
    }
}

private final class ImageSaver: NSObject {
    private let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func saveImage(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(didFinishSavingImage), nil)
    }
    @objc func didFinishSavingImage(
        _ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer
    ) {
        completion(error == nil)
    }
}

// MARK: API
enum ImageClientKey: DependencyKey {
    static let liveValue = ImageClient.live
    static let previewValue = ImageClient.noop
    static let testValue = ImageClient.unimplemented
}

extension DependencyValues {
    var imageClient: ImageClient {
        get { self[ImageClientKey.self] }
        set { self[ImageClientKey.self] = newValue }
    }
}

// MARK: Test
extension ImageClient {
    static let noop: Self = .init(
        prefetchImages: { _ in },
        saveImageToPhotoLibrary: { _, _ in false },
        downloadImage: { _ in .success(UIImage()) },
        retrieveImage: { _ in .success(UIImage()) },
        loadReaderImageAsset: { _, _ in
            .success(ReaderImageAsset(image: UIImage(), data: Data()))
        }
    )

    static let unimplemented: Self = .init(
        prefetchImages: XCTestDynamicOverlay.unimplemented("\(Self.self).prefetchImages"),
        saveImageToPhotoLibrary: XCTestDynamicOverlay.unimplemented("\(Self.self).saveImageToPhotoLibrary"),
        downloadImage: XCTestDynamicOverlay.unimplemented("\(Self.self).downloadImage"),
        retrieveImage: XCTestDynamicOverlay.unimplemented("\(Self.self).retrieveImage"),
        loadReaderImageAsset: XCTestDynamicOverlay.unimplemented("\(Self.self).loadReaderImageAsset")
    )
}
