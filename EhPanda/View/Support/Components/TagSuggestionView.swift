//
//  TagSuggestionView.swift
//  EhPanda
//
//  Created by xioxin on 2022/2/15.
//

import SwiftUI
import Kingfisher
import SFSafeSymbols

struct TagSuggestionView: View {
    @Binding private var keyword: String
    private let translations: [String: TagTranslation]
    private let translationsRevision: String
    private let showsImages: Bool
    private let isEnabled: Bool

    @StateObject private var translationHandler = TagTranslationHandler()

    init(keyword: Binding<String>, tagTranslator: TagTranslator, showsImages: Bool, isEnabled: Bool) {
        _keyword = keyword
        translations = tagTranslator.translations
        translationsRevision = tagTranslator.revisionIdentifier
        self.showsImages = showsImages
        self.isEnabled = isEnabled
    }

    private func refreshAnalysis() {
        guard isEnabled else {
            translationHandler.clear()
            return
        }
        let normalized = TagTranslationHandler.normalize(keyword)
        if normalized != keyword {
            let binding = _keyword
            DispatchQueue.main.async { binding.wrappedValue = normalized }
        }
        translationHandler.schedule(
            keyword: normalized, translations: translations, revision: translationsRevision
        )
    }

    var body: some View {
        Group {
            if isEnabled {
                let suggestions = translationHandler.suggestions

                if DeviceUtil.isPhone {
                    Text(L10n.Localizable.Searchable.Title.matchesCount(suggestions.count))
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }

                ForEach(suggestions) { suggestion in
                    SuggestionCell(
                        suggestion: suggestion,
                        // iPad supplies the completion up front, so the terms preceding the tag
                        // being completed are preserved instead of being replaced.
                        searchCompletion: translationHandler
                            .completedKeyword(suggestion: suggestion, keyword: keyword),
                        showsImages: showsImages,
                        action: { translationHandler.autoComplete(suggestion: suggestion, keyword: &keyword) }
                    )
                }
            } else {
                EmptyView()
            }
        }
        .onAppear(perform: refreshAnalysis)
        .onChange(of: keyword) { _ in refreshAnalysis() }
        .onChange(of: translationsRevision) { _ in refreshAnalysis() }
        .onChange(of: isEnabled) { _ in refreshAnalysis() }
    }
}

// MARK: SuggestionCell
private struct SuggestionCell: View {
    private let suggestion: TagSuggestion
    private let searchCompletion: String
    private let showsImages: Bool
    private let action: () -> Void

    init(suggestion: TagSuggestion, searchCompletion: String, showsImages: Bool, action: @escaping () -> Void) {
        self.suggestion = suggestion
        self.searchCompletion = searchCompletion
        self.showsImages = showsImages
        self.action = action
    }

    private var displayValue: String {
        let value = suggestion.displayValue
        return showsImages ? value : value.emojisRipped
    }

    var body: some View {
        if DeviceUtil.isPhone {
            HStack(spacing: 20) {
                Image(systemSymbol: .magnifyingglass)

                VStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        Text(displayValue.localizedKey)

                        if let imageURL = suggestion.tag.valueImageURL, showsImages {
                            Image(systemSymbol: .photo)
                                .opacity(0)
                                .overlay(
                                    KFImage(imageURL)
                                        .resizable()
                                        .scaledToFit()
                                )
                        }
                    }
                    .font(.callout)
                    .lineLimit(1)

                    Text(suggestion.displayKey.localizedKey)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .allowsHitTesting(false)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        } else {
            (Text(displayValue.localizedKey) + Text("\n") + Text(suggestion.displayKey.localizedKey))
                .searchCompletion(searchCompletion)
        }
    }
}

// MARK: TagTranslationHandler
final class TagTranslationHandler: ObservableObject {
    @Published private(set) var suggestions = [TagSuggestion]()

    private static let suggestionLimit = 10
    private static let debounceInterval: Duration = .milliseconds(150)

    /// Normalized projection of the translator. Building it once per translator revision
    /// avoids lowercasing tens of thousands of strings on every keystroke.
    private struct IndexedTranslation {
        let translation: TagTranslation
        let normalizedKey: String
        let normalizedValue: String

        init(translation: TagTranslation) {
            self.translation = translation
            normalizedKey = translation.key.lowercased()
            normalizedValue = translation.value.lowercased()
        }
    }

    private var indexedTranslations = [IndexedTranslation]()
    private var indexedRevision: String?
    private var scheduledInput: String?
    private var analysisTask: Task<Void, Never>?

    deinit {
        analysisTask?.cancel()
    }

    /// Collapses repeated spaces and normalizes the full-width colon so that matching does
    /// not depend on incidental input formatting.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "：", with: ":")
    }

    func clear() {
        analysisTask?.cancel()
        analysisTask = nil
        scheduledInput = nil
        guard !suggestions.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.suggestions = []
        }
    }

    func schedule(keyword: String, translations: [String: TagTranslation], revision: String) {
        let input = [revision, keyword].joined(separator: "\u{1}")
        guard scheduledInput != input else { return }
        scheduledInput = input
        analysisTask?.cancel()

        guard !keyword.isEmpty else {
            publish([], expectedInput: input)
            return
        }

        let corpus: [IndexedTranslation]? = indexedRevision == revision ? indexedTranslations : nil
        let limit = TagTranslationHandler.suggestionLimit
        let interval = TagTranslationHandler.debounceInterval
        analysisTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }

            let resolved: [IndexedTranslation]
            if let corpus = corpus {
                resolved = corpus
            } else {
                let built = translations.values.map { IndexedTranslation(translation: $0) }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self = self, self.scheduledInput == input, !Task.isCancelled else { return }
                    self.indexedTranslations = built
                    self.indexedRevision = revision
                }
                resolved = built
            }

            guard !Task.isCancelled else { return }
            let result = TagTranslationHandler.computeSuggestions(
                keyword: keyword, corpus: resolved, limit: limit
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                // `TagSuggestion` now has value identity, so an unchanged result can be dropped
                // instead of re-rendering every row.
                guard let self = self, self.scheduledInput == input,
                      !Task.isCancelled, self.suggestions != result
                else { return }
                self.suggestions = result
            }
        }
    }

    /// The full replacement query for a suggestion, preserving every term that precedes the
    /// token being completed.
    func completedKeyword(suggestion: TagSuggestion, keyword: String) -> String {
        let replacement = suggestion.tag.searchKeyword + " "
        guard !suggestion.originalKeyword.isEmpty,
              let range = keyword.range(
                of: suggestion.originalKeyword, options: [.backwards, .caseInsensitive]
              ),
              range.upperBound == keyword.endIndex
        else {
            guard !keyword.isEmpty, !keyword.hasSuffix(" ") else { return keyword + replacement }
            return keyword + " " + replacement
        }
        return String(keyword[keyword.startIndex..<range.lowerBound]) + replacement
    }

    func autoComplete(suggestion: TagSuggestion, keyword: inout String) {
        keyword = completedKeyword(suggestion: suggestion, keyword: keyword)
    }

    private func publish(_ newSuggestions: [TagSuggestion], expectedInput: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.scheduledInput == expectedInput,
                  self.suggestions != newSuggestions
            else { return }
            self.suggestions = newSuggestions
        }
    }

    private static func computeSuggestions(
        keyword: String, corpus: [IndexedTranslation], limit: Int
    ) -> [TagSuggestion] {
        guard let regex = Defaults.Regex.tagSuggestion else { return [] }
        // `NSRegularExpression` ranges are UTF-16 based; `String.count` counts graphemes, so
        // an emoji earlier in the query would silently truncate the searched range.
        let range = NSRange(keyword.startIndex..<keyword.endIndex, in: keyword)
        let keywords: [String] = regex.matches(in: keyword, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: keyword) else { return nil }
            return String(keyword[matchRange])
        }

        var result = [TagSuggestion]()
        var existingWords = Set<String>()
        let lastCompletedTagIndex = keywords.lastIndex(where: { ["\"", "$"].contains($0.last) })
        for index in (lastCompletedTagIndex ?? 0)..<keywords.count {
            if Task.isCancelled { return [] }
            let keywordList = keywords[index...]
            guard !keywordList.isEmpty else { continue }
            for suggestion in topSuggestions(
                corpus: corpus, keyword: keywordList.joined(separator: " "), limit: limit
            ) where !existingWords.contains(suggestion.tag.searchKeyword) {
                existingWords.insert(suggestion.tag.searchKeyword)
                result.append(suggestion)
            }
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    private static func topSuggestions(
        corpus: [IndexedTranslation], keyword: String, limit: Int
    ) -> [TagSuggestion] {
        let originalKeyword = keyword
        var keyword = keyword
        var namespace: String?
        let namespaceAbbreviations = TagNamespace.abbreviations

        if let colon = keyword.firstIndex(of: ":") {
            let key = String(keyword[keyword.startIndex..<colon])
            if let index = namespaceAbbreviations.firstIndex(where: {
                $0.caseInsensitiveEqualsTo(key) || $1.caseInsensitiveEqualsTo(key)
            }) {
                namespace = namespaceAbbreviations[index].key
                keyword = String(keyword[keyword.index(colon, offsetBy: 1)..<keyword.endIndex])
            }
        }

        let matchesNamespace = namespace != nil
        var candidates = corpus
        if let namespace = namespace {
            candidates = candidates.filter { $0.translation.namespace.rawValue == namespace }
        }

        if matchesNamespace, keyword.isEmpty {
            // Returns suggestion based on namespace only
            return candidates.prefix(limit).map {
                .init(
                    tag: $0.translation, weight: 0, keyRange: nil, valueRange: nil,
                    originalKeyword: originalKeyword, matchesNamespace: true
                )
            }
        }

        let normalizedKeyword = keyword.lowercased()
        guard !normalizedKeyword.isEmpty else { return [] }

        // Bounded insertion keeps selection O(n · limit) instead of sorting the whole corpus.
        var best = [TagSuggestion]()
        best.reserveCapacity(limit + 1)
        for candidate in candidates {
            guard candidate.normalizedKey.contains(normalizedKeyword)
                    || candidate.normalizedValue.contains(normalizedKeyword)
            else { continue }
            let suggestion = candidate.translation.getSuggestion(
                keyword: keyword, originalKeyword: originalKeyword, matchesNamespace: matchesNamespace
            )
            guard suggestion.weight > 0 else { continue }
            if let index = best.firstIndex(where: { $0.weight < suggestion.weight }) {
                best.insert(suggestion, at: index)
                if best.count > limit { best.removeLast() }
            } else if best.count < limit {
                best.append(suggestion)
            }
        }
        return best
    }
}
