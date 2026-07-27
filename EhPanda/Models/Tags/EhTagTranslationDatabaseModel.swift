//
//  EhTagTranslationDatabaseModel.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/20.
//

import Foundation

struct EhTagTranslationDatabaseResponse: Codable {
    struct Item: Codable {
        let name: String
        var intro: String?
        var links: String?
    }

    struct Model: Codable {
        let namespace: String
        let data: [String: Item]

        var tagTranslations: [TagTranslation] {
            guard let namespace = TagNamespace(rawValue: namespace) else { return .init() }
            return data.map {
                .init(
                    namespace: namespace, key: $0, value: $1.name,
                    description: $1.intro, linksString: $1.links
                )
            }
        }
    }

    let data: [Model]

    // Remote and user-imported databases can repeat a namespace, and the flattened
    // `namespace + key` composite can collide across namespaces as well. Duplicates are resolved
    // deterministically by keeping the first occurrence, in the order the namespaces are listed in
    // the document, instead of trapping the way `Dictionary(uniqueKeysWithValues:)` does.
    var tagTranslations: [String: TagTranslation] {
        var translations = [String: TagTranslation]()
        for translation in data.flatMap(\.tagTranslations) {
            let key = translation.namespace.rawValue + translation.key
            if translations[key] == nil {
                translations[key] = translation
            }
        }
        return translations
    }
}
