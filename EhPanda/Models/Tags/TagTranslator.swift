//
//  TagTranslator.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/04.
//

import Foundation
import CryptoKit

struct TagTranslator: Codable, Equatable {
    var language: TranslatableLanguage?
    var hasCustomTranslations = false
    var updatedDate: Date = .distantPast
    var translations = [String: TagTranslation]()

    var revisionIdentifier: String {
        let contentIdentity = translations
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { key, translation in
                [
                    key,
                    translation.namespace.rawValue,
                    translation.key,
                    translation.value,
                    translation.description ?? "",
                    translation.linksString ?? ""
                ]
                .joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(contentIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return [
            String(describing: language),
            String(updatedDate.timeIntervalSince1970),
            hasCustomTranslations ? "custom" : "default",
            String(translations.count),
            digest
        ]
        .joined(separator: "|")
    }

    func lookup(word: String, returnOriginal: Bool) -> (String, TagTranslation?) {
        guard !returnOriginal else { return (word, nil) }
        let (lhs, rhs) = word.stringsBesideColon

        var key = rhs
        if let lhs = lhs {
            key = lhs + rhs
        }
        guard let translation = translations[key] else { return (word, nil) }

        var result = translation.displayValue
        if let lhs = lhs {
            result = [lhs, ":", result].joined()
        }
        return (result, translation)
    }
}

extension TagTranslator: CustomStringConvertible {
    var description: String {
        let params = String(describing: [
            "language": language as Any,
            "updatedDate": updatedDate,
            "translationsCount": translations.count,
            "hasCustomTranslations": hasCustomTranslations
        ])
        return "TagTranslator(\(params))"
    }
}
