//
//  Misc.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/01/15.
//

import Foundation
import SwiftyBeaver

typealias Logger = SwiftyBeaver
typealias FavoritesSortOrder = EhSetting.FavoritesSortOrder

enum DateSeekDirection: Equatable {
    case newer
    case older
}

struct DateSeekNavigation: Equatable {
    let newerURL: URL?
    let olderURL: URL?
    let minimumDate: Date
    let maximumDate: Date

    var dateRange: ClosedRange<Date> {
        minimumDate...maximumDate
    }

    func clampedDate(_ date: Date = Date()) -> Date {
        min(max(date, minimumDate), maximumDate)
    }

    func seekURL(date: Date, direction: DateSeekDirection) -> URL? {
        let baseURL = direction == .newer ? newerURL : olderURL
        return baseURL?.appending(queryItems: ["seek": Self.dateFormatter.string(from: date)])
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

protocol DateFormattable {
    var originalDate: Date { get }
}
extension DateFormattable {
    var formattedDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        formatter.calendar = Calendar.current
        return formatter.string(from: originalDate)
    }
}

struct PageNumber: Equatable {
    var current = 0
    var maximum = 0
    var lastItemTimestamp: String?
    var isNextButtonEnabled = false
    var dateSeekNavigation: DateSeekNavigation?

    var isSinglePage: Bool {
        current == 0 && maximum == 0
    }
    func hasNextPage(isNumericBased: Bool = false) -> Bool {
        isNumericBased ? current < maximum : isNextButtonEnabled
    }
    mutating func resetPages() {
        self = Self()
    }
}

struct QuickSearchWord: Codable, Equatable, Identifiable {
    static var empty: Self { .init(name: "", content: "") }

    var id: UUID = .init()
    var name: String
    var content: String
}

enum LoadingState: Equatable, Hashable {
    case idle
    case loading
    case failed(AppError)
}
