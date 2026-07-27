//
//  PageHandler.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/09.
//

import SwiftUI

// Everything that changes how physical pages are grouped into pager containers.
// Whenever it changes the container is replaced, so the previously stored container
// index means a different page and has to be remapped through the physical page.
struct ReadingLayoutKey: Equatable {
    let isLandscape: Bool
    let readingDirection: ReadingDirection
    let enablesDualPageMode: Bool
    let exceptCover: Bool

    init(setting: Setting, isLandscape: Bool) {
        self.isLandscape = isLandscape
        readingDirection = setting.readingDirection
        enablesDualPageMode = setting.enablesDualPageMode
        exceptCover = setting.exceptCover
    }
}

final class PageHandler: ObservableObject {
    @Published var sliderValue: Float = 1 {
        didSet {
            Logger.info("sliderValue.didSet", context: ["sliderValue": sliderValue])
        }
    }

    // The canonical position of the reader. `Page.index` is only a container index and
    // is invalidated by every layout change, so progress is derived from this instead.
    private(set) var physicalPage: Int = 1
    // The layout the canonical page and the pager's container index were last known to
    // agree under. SwiftUIPager receives the new data source in the same update pass
    // that changes the key and can clamp and publish an index before the remap runs, so
    // an index arriving under a different key is part of the transition, not a page turn.
    private(set) var reconciledLayoutKey: ReadingLayoutKey?
    private var pendingLayoutRemap = false

    func setPhysicalPage(_ page: Int) {
        physicalPage = max(1, page)
    }

    func setReconciledLayout(_ key: ReadingLayoutKey) {
        reconciledLayoutKey = key
    }

    func matchesReconciledLayout(_ key: ReadingLayoutKey) -> Bool {
        reconciledLayoutKey == key
    }

    // A remap replaces the container under the pager. The index change it produces —
    // including any index the pager clamps on its way to the new bounds — describes the
    // layout, not the reader, and must not be persisted as progress.
    func beginLayoutRemap() {
        pendingLayoutRemap = true
    }

    func consumeLayoutRemap() -> Bool {
        defer { pendingLayoutRemap = false }
        return pendingLayoutRemap
    }

    func mapFromPager(index: Int, pageCount: Int, setting: Setting, isLandscape: Bool = DeviceUtil.isLandscape) -> Int {
        guard isLandscape && setting.enablesDualPageMode
                && setting.readingDirection != .vertical
        else { return index + 1 }
        guard index > 0 else { return 1 }

        let result = setting.exceptCover ? index * 2 : index * 2 + 1

        if result + 1 == pageCount {
            return pageCount
        } else {
            return result
        }
    }

    func mapToPager(index: Int, setting: Setting, isLandscape: Bool = DeviceUtil.isLandscape) -> Int {
        guard isLandscape && setting.enablesDualPageMode
                && setting.readingDirection != .vertical
        else { return index - 1 }
        guard index > 1 else { return 0 }

        return setting.exceptCover ? index / 2 : (index - 1) / 2
    }
}
