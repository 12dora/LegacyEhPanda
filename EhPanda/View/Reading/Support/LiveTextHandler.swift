//
//  LiveTextHandler.swift
//  EhPanda
//
//  Created by xioxin on 2022/2/12.
//
//  swiftlint:disable line_length
//  Refercence
//  https://www.codeproject.com/Articles/15573/2D-Polygon-Collision-Detection
//  https://developer.apple.com/documentation/vision/recognizing_text_in_images
//  https://github.com/TelegramMessenger/Telegram-iOS/blob/2a32c871882c4e1b1ccdecd34fccd301723b30d9/submodules/Translate/Sources/Translate.swift
//  https://github.com/TelegramMessenger/Telegram-iOS/blob/0be460b147321b7455247aedca81ca819702959d/submodules/ImageContentAnalysis/Sources/ImageContentAnalysis.swift
//  swiftlint:enable line_length
//

import UIKit
import ImageIO
import Vision
import SwiftUI
import Foundation

// Analyzing a page costs a full-resolution decode plus a Vision text request — hundreds
// of milliseconds and tens of megabytes on the devices this build targets. The reader
// reports its loaded pages as a set that changes on every image, so firing one request
// per notification re-walked the whole set and started the same page again for as long
// as it had not finished, which is what produced duplicate decodes, stutter and heat.
//
// Everything therefore goes through one scheduler. A page is enqueued at most once,
// deduplicated across the queued / in-flight / resolved states, marked before the first
// suspension point, executed closest-to-the-reader first and only a couple at a time.
// Every stage (image fetch task and Vision request alike) is retained so it can be
// cancelled, and every hand-off carries the generation it was started in so nothing can
// publish into a reader that has been dismissed or had Live Text switched off.
//
// Scheduler state is confined to the main thread: every entry point is a SwiftUI
// callback, and every background stage hops back to main before touching it.
final class LiveTextHandler: ObservableObject {
    @Published var enablesLiveText = false
    @Published private(set) var liveTextGroups = [Int: [LiveTextGroup]]()
    @Published private(set) var focusedLiveTextGroup: LiveTextGroup?

    // Two at a time keeps one page decoding while another is recognized without ever
    // holding more than a couple of full-resolution bitmaps alive at once.
    private static let maximumConcurrentAnalyses = 2

    private var generation = 0
    private var queuedIndices = [Int]()
    private var inFlightIndices = Set<Int>()
    // Pages that finished, failed or produced no image. They are never retried within a
    // generation, which is what bounds the work; toggling Live Text off and on again
    // starts a new generation and gives unfinished pages another chance.
    private var resolvedIndices = Set<Int>()
    private var pendingURLs = [Int: URL]()
    private var fetchTasks = [Int: Task<Void, Never>]()
    private var visionRequests = [Int: VNRequest]()
    private var priorityIndex = 1
    private var recognitionLanguages: [String]?
    private var imageProvider: ((URL) async -> UIImage?)?

    deinit {
        // `deinit` can run off the main thread, so the handles are cancelled directly
        // instead of going through the scheduler.
        fetchTasks.values.forEach { $0.cancel() }
        visionRequests.values.forEach { $0.cancel() }
    }

    func setFocusedLiveTextGroup(_ group: LiveTextGroup) {
        Logger.info("setFocusedLiveTextGroup", context: ["group": group])
        focusedLiveTextGroup = group
    }

    // Safe to call on every change of the reader's loaded-page set: pages that are
    // queued, running or already resolved are skipped, so no page is ever fetched or
    // recognized twice.
    func scheduleAnalyses(
        indices: Set<Int>, imageURLs: [Int: URL], priorityIndex: Int,
        recognitionLanguages: [String]?, imageProvider: @escaping (URL) async -> UIImage?
    ) {
        self.priorityIndex = priorityIndex
        self.recognitionLanguages = recognitionLanguages
        self.imageProvider = imageProvider

        guard enablesLiveText else { return }

        for index in indices.sorted() {
            guard let url = imageURLs[index],
                  !resolvedIndices.contains(index),
                  !inFlightIndices.contains(index),
                  pendingURLs[index] == nil
            else { continue }
            pendingURLs[index] = url
            queuedIndices.append(index)
        }
        // The reader only ever looks at a couple of pages, so the queue is ordered by
        // distance from the current one instead of by arrival.
        let anchor = self.priorityIndex
        queuedIndices.sort { abs($0 - anchor) < abs($1 - anchor) }

        Logger.info("scheduleAnalyses", context: [
            "queued": queuedIndices.count, "inFlight": inFlightIndices.count,
            "resolved": resolvedIndices.count
        ])
        pumpQueue()
    }

    func startEnabledGeneration() {
        generation &+= 1
        fetchTasks.values.forEach { $0.cancel() }
        visionRequests.values.forEach { $0.cancel() }
        queuedIndices.removeAll()
        inFlightIndices.removeAll()
        pendingURLs.removeAll()
        fetchTasks.removeAll()
        visionRequests.removeAll()
        // Successful OCR groups can be reused after a toggle. Failed/no-image pages
        // have no published group, so they are deliberately made retryable again.
        resolvedIndices = Set(liveTextGroups.keys)
    }

    // Stops every stage and invalidates everything already in flight. Used both when
    // Live Text is switched off and when the reader disappears: an unretained fetch used
    // to survive both and enqueue a fresh Vision request afterwards.
    func cancelRequests() {
        generation &+= 1
        let tasks = fetchTasks
        let requests = visionRequests
        fetchTasks.removeAll()
        visionRequests.removeAll()
        queuedIndices.removeAll()
        inFlightIndices.removeAll()
        pendingURLs.removeAll()
        resolvedIndices = Set(liveTextGroups.keys)
        focusedLiveTextGroup = nil
        Logger.info("cancelRequests", context: [
            "fetchTasksCount": tasks.count, "processingRequestsCount": requests.count
        ])
        tasks.values.forEach { $0.cancel() }
        requests.values.forEach { $0.cancel() }
    }

    private func pumpQueue() {
        guard enablesLiveText else { return }
        while inFlightIndices.count < Self.maximumConcurrentAnalyses, !queuedIndices.isEmpty {
            startAnalysis(index: queuedIndices.removeFirst())
        }
    }

    private func startAnalysis(index: Int) {
        guard let url = pendingURLs[index], let imageProvider = imageProvider else {
            resolvedIndices.insert(index)
            pendingURLs[index] = nil
            return
        }
        // Marked before the first suspension point. Any further notification about this
        // page while the fetch is in flight is deduplicated instead of starting a second
        // decode — the whole point of the scheduler.
        inFlightIndices.insert(index)
        let startedGeneration = generation
        let languages = recognitionLanguages
        fetchTasks[index] = Task { [weak self] in
            let image = await imageProvider(url)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                self?.startRecognition(
                    image: image, index: index, generation: startedGeneration,
                    recognitionLanguages: languages
                )
            }
        }
    }

    private func startRecognition(
        image: UIImage?, index: Int, generation: Int, recognitionLanguages: [String]?
    ) {
        guard self.generation == generation else { return }
        fetchTasks[index] = nil
        pendingURLs[index] = nil

        guard let image = image, let cgImage = image.cgImage else {
            Logger.info("analyzeImage image not found", context: ["index": index])
            finishAnalysis(index: index, generation: generation)
            return
        }
        Logger.info("analyzeImage", context: [
            "index": index, "recognitionLanguages": recognitionLanguages as Any
        ])

        // `image.size` is the oriented size, so the observations Vision returns are
        // normalized against the same rectangle the overlay is drawn in — but only if
        // Vision is told the orientation. Dropping it recognized EXIF-rotated scans
        // sideways and placed their highlights in the wrong corner.
        let size = image.size
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        let request = VNRecognizeTextRequest { [weak self] request, error in
            self?.recognitionHandler(
                request: request, error: error, size: size,
                index: index, generation: generation
            )
        }
        request.usesLanguageCorrection = true
        request.preferBackgroundProcessing = true
        if let languages = recognitionLanguages {
            request.recognitionLanguages = languages
        }
        visionRequests[index] = request

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try requestHandler.perform([request])
            } catch {
                Logger.info("Unable to perform the requests.", context: ["error": error])
                DispatchQueue.main.async {
                    self?.finishAnalysis(index: index, generation: generation)
                }
            }
        }
    }

    // Called on the queue that performed the request, which is already off the main
    // thread, so the quadratic grouping pass runs right here.
    private func recognitionHandler(
        request: VNRequest, error: Error?, size: CGSize, index: Int, generation: Int
    ) {
        Logger.info("recognitionHandler", context: [
            "error": error as Any, "index": index
        ])
        guard error == nil else {
            DispatchQueue.main.async { [weak self] in
                self?.finishAnalysis(index: index, generation: generation)
            }
            return
        }
        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        let groups = Self.makeGroups(observations: observations, size: size)
        DispatchQueue.main.async { [weak self] in
            self?.publish(groups: groups, index: index, generation: generation)
        }
    }

    private func publish(groups: [LiveTextGroup], index: Int, generation: Int) {
        // Last gate before any state is written: a reader that was dismissed or had Live
        // Text switched off between `perform` and here has already bumped the generation.
        guard self.generation == generation else { return }
        liveTextGroups[index] = groups
        finishAnalysis(index: index, generation: generation)
    }

    // Releases the slot the page occupied and starts the next one. Idempotent, because a
    // cancelled Vision request can report both a throwing `perform` and a completion.
    private func finishAnalysis(index: Int, generation: Int) {
        guard self.generation == generation else { return }
        resolvedIndices.insert(index)
        fetchTasks[index] = nil
        visionRequests[index] = nil
        pendingURLs[index] = nil
        guard inFlightIndices.remove(index) != nil else { return }
        pumpQueue()
    }

    private static func makeGroups(
        observations: [VNRecognizedTextObservation], size: CGSize
    ) -> [LiveTextGroup] {
        let blocks: [LiveTextBlock] = observations.compactMap { observation in
            guard let recognizedText = observation.topCandidates(1).first?.string else { return nil }
            return .init(
                text: recognizedText,
                bounds: .init(
                    topLeft: observation.topLeft.verticalReversed,
                    topRight: observation.topRight.verticalReversed,
                    bottomLeft: observation.bottomLeft.verticalReversed,
                    bottomRight: observation.bottomRight.verticalReversed
                )
            )
        }

        var groupData = [[LiveTextBlock]]()
        blocks.forEach { newItem in
            if let groupIndex = groupData.firstIndex(where: { items in
                items.first { item in
                    let angle = abs(item.bounds.getAngle(size) - newItem.bounds.getAngle(size))
                        .truncatingRemainder(dividingBy: 360.0)
                    let isAngleValid = angle < 5 || angle > (360 - 5)
                    let aHeight = item.bounds.getHeight(size)
                    let bHeight = newItem.bounds.getHeight(size)
                    let isHeightValid = abs(aHeight - bHeight) < (min(aHeight, bHeight) / 2)

                    guard isAngleValid && isHeightValid else { return false }
                    return polygonsIntersecting(
                        lhs: item.bounds.expandingHalfHeight(size).edges,
                        rhs: newItem.bounds.expandingHalfHeight(size).edges
                    )
                } != nil
            }) {
                groupData[groupIndex].append(newItem)
            } else {
                groupData.append([newItem])
            }
        }

        return groupData.compactMap(LiveTextGroup.init)
    }

    private static func polygonsIntersecting(lhs: [CGPoint], rhs: [CGPoint]) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty, lhs.count == rhs.count else { return false }
        for points in [lhs, rhs] {
            for index1 in 0..<points.count {
                let index2 = (index1 + 1) % points.count
                let point1 = points[index1]
                let point2 = points[index2]

                let basis = CGPoint(x: point2.y - point1.y, y: point1.x - point2.x)

                var minA: Double?
                var maxA: Double?
                lhs.forEach { point in
                    let projection = basis.x * point.x + basis.y * point.y
                    if let unwrappedMinA = minA {
                        minA = min(unwrappedMinA, projection)
                    } else {
                        minA = projection
                    }
                    if let unwrappedMaxA = maxA {
                        maxA = max(unwrappedMaxA, projection)
                    } else {
                        maxA = projection
                    }
                }

                var minB: Double?
                var maxB: Double?
                rhs.forEach { point in
                    let projection = basis.x * point.x + basis.y * point.y
                    if let unwrappedMinB = minB {
                        minB = min(unwrappedMinB, projection)
                    } else {
                        minB = projection
                    }
                    if let unwrappedMaxB = maxB {
                        maxB = max(unwrappedMaxB, projection)
                    } else {
                        maxB = projection
                    }
                }

                guard let minA = minA, let maxA = maxA,
                      let minB = minB, let maxB = maxB
                else { return false }

                if maxA < minB || maxB < minA {
                    return false
                }
            }
        }
        return true
    }
}

private extension CGPoint {
    var verticalReversed: CGPoint {
        .init(x: x, y: 1 - y)
    }
}

private extension CGImagePropertyOrientation {
    // Vision has no notion of UIKit's orientation flag: handing it a `CGImage` without
    // one recognizes an EXIF-rotated page in the wrong axis and places every highlight
    // in the wrong corner. The mapping is the one Apple documents for
    // `UIImage.Orientation` — matching by name, not by raw value.
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .left
        case .leftMirrored:
            self = .leftMirrored
        case .right:
            self = .right
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
