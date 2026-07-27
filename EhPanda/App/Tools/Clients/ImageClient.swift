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
import UniformTypeIdentifiers

struct ImageClient {
    let prefetchImages: ([URL]) -> Void
    let saveImageToPhotoLibrary: (ReaderImageAsset, URL?) async -> Bool
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
        // The original container is always attempted first so "Save Original" really
        // saves the original. Only if the photo library refuses it — WebP is the one
        // reader format it is not documented to accept — is the re-encode attempted,
        // so preservation is decided by the OS at runtime instead of being assumed.
        saveImageToPhotoLibrary: { (asset, sourceURL) in
            for export in asset.photoLibraryExports(sourceURL: sourceURL) {
                let isSuccess = await withCheckedContinuation { continuation in
                    PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = export.filename
                        options.uniformTypeIdentifier = export.uti
                        request.addResource(with: .photo, data: export.data, options: options)
                    } completionHandler: { (isSuccess, _) in
                        continuation.resume(returning: isSuccess)
                    }
                }
                if isSuccess { return true }
            }
            return false
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
        switch await loadReaderImageAsset(url, nil) {
        case .success(let asset):
            return .success(asset.image)
        case .failure(let error):
            return .failure(error)
        }
    }
}

// MARK: Export
// A page's source container carries its metadata, colour profile and size. Reducing it
// to a UIImage and letting Kingfisher re-encode with `.unknown` produced a PNG for every
// JPEG/WebP page, which is the opposite of "Save Original".
private enum ReaderImageFileFormat {
    case jpeg, png, gif, webP, heic

    var uti: String {
        switch self {
        case .jpeg:
            return UTType.jpeg.identifier
        case .png:
            return UTType.png.identifier
        case .gif:
            return UTType.gif.identifier
        case .webP:
            return UTType.webP.identifier
        case .heic:
            return UTType.heic.identifier
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg:
            return "jpg"
        case .png:
            return "png"
        case .gif:
            return "gif"
        case .webP:
            return "webp"
        case .heic:
            return "heic"
        }
    }

    init?(data: Data) {
        func matches(_ bytes: [UInt8], at offset: Int) -> Bool {
            guard data.count >= offset + bytes.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: bytes.count)
            return Array(data[start..<end]) == bytes
        }
        if matches([0xFF, 0xD8, 0xFF], at: 0) {
            self = .jpeg
        } else if matches([0x89, 0x50, 0x4E, 0x47], at: 0) {
            self = .png
        } else if matches([0x47, 0x49, 0x46, 0x38], at: 0) {
            self = .gif
        } else if matches(Array("RIFF".utf8), at: 0), matches(Array("WEBP".utf8), at: 8) {
            self = .webP
        } else if matches(Array("ftypheic".utf8), at: 4) || matches(Array("ftypheix".utf8), at: 4)
                    || matches(Array("ftypmif1".utf8), at: 4) || matches(Array("ftypmsf1".utf8), at: 4) {
            self = .heic
        } else {
            return nil
        }
    }
}

private struct ReaderImageExport {
    let data: Data
    let uti: String
    let filename: String
}

private extension ReaderImageAsset {
    // Ordered candidates: the source container first, a re-encode as the fallback the
    // photo library is guaranteed to accept.
    func photoLibraryExports(sourceURL: URL?) -> [ReaderImageExport] {
        let stem = sourceURL.map { $0.deletingPathExtension().lastPathComponent } ?? ""
        let base = stem.isEmpty ? "image" : stem
        var exports = [ReaderImageExport]()
        let sourceFormat = ReaderImageFileFormat(data: data)
        if let sourceFormat {
            exports.append(.init(
                data: data, uti: sourceFormat.uti, filename: "\(base).\(sourceFormat.fileExtension)"
            ))
        }
        let fallbackFormat: ReaderImageFileFormat = isAnimated ? .gif : .png
        guard fallbackFormat != sourceFormat,
              let encoded = image.kf.data(format: isAnimated ? .GIF : .unknown)
        else { return exports }
        exports.append(.init(
            data: encoded, uti: fallbackFormat.uti,
            filename: "\(base).\(fallbackFormat.fileExtension)"
        ))
        return exports
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
