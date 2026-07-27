//
//  QuickSearchReducer.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/20.
//

import SwiftUI
import ComposableArchitecture

struct QuickSearchReducer: Reducer {
    enum Route: Equatable {
        case newWord
        case editWord
        case deleteWord(QuickSearchWord)
    }

    enum FocusField {
        case name
        case content
    }

    private enum CancelID {
        case fetchQuickSearchWords
    }

    struct State: Equatable {
        @BindingState var route: Route?
        @BindingState var focusedField: FocusField?
        @BindingState var editingWord: QuickSearchWord = .empty
        @BindingState var listEditMode: EditMode = .inactive
        var isListEditing: Bool {
            get { listEditMode == .active }
            set { listEditMode = newValue ? .active : .inactive }
        }

        var loadingState: LoadingState = .idle
        var quickSearchWords = [QuickSearchWord]()
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case setNavigation(Route?)
        case clearSubStates

        case syncQuickSearchWords

        case toggleListEditing
        case setEditingWord(QuickSearchWord)

        case appendWord
        case editWord
        case deleteWord(QuickSearchWord)
        case deleteWordWithOffsets(IndexSet)
        case moveWord(IndexSet, Int)

        case teardown
        case fetchQuickSearchWords
        case fetchQuickSearchWordsDone([QuickSearchWord])
    }

    @Dependency(\.databaseClient) private var databaseClient

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding(\.$route):
                return state.route == nil ? .send(.clearSubStates) : .none

            case .binding:
                return .none

            case .setNavigation(let route):
                state.route = route
                return route == nil ? .send(.clearSubStates) : .none

            case .clearSubStates:
                state.focusedField = nil
                state.editingWord = .empty
                return .none

            case .syncQuickSearchWords:
                return .run { [state] _ in
                    let result = await databaseClient.updateQuickSearchWords(state.quickSearchWords)
                    if case .failure(let error) = result {
                        Logger.error("Failed to persist quick search words.", context: ["error": "\(error)"])
                    }
                }

            case .toggleListEditing:
                state.isListEditing.toggle()
                return .none

            case .setEditingWord(let word):
                state.editingWord = word
                return .none

            case .appendWord:
                // A blank record would persist as an actionable row that performs an empty search.
                let appendedWord = state.editingWord.trimmed
                guard appendedWord.isValid else { return .none }
                state.editingWord = appendedWord
                state.quickSearchWords.append(appendedWord)
                return .send(.syncQuickSearchWords)

            case .editWord:
                let editedWord = state.editingWord.trimmed
                guard editedWord.isValid,
                      let index = state.quickSearchWords.firstIndex(where: { $0.id == editedWord.id })
                else { return .none }
                state.editingWord = editedWord
                state.quickSearchWords[index] = editedWord
                return .send(.syncQuickSearchWords)

            case .deleteWord(let word):
                state.quickSearchWords = state.quickSearchWords.filter({ $0 != word })
                return .send(.syncQuickSearchWords)

            case .deleteWordWithOffsets(let offsets):
                state.quickSearchWords.remove(atOffsets: offsets)
                return .send(.syncQuickSearchWords)

            case .moveWord(let source, let destination):
                state.quickSearchWords.move(fromOffsets: source, toOffset: destination)
                return .send(.syncQuickSearchWords)

            case .teardown:
                return .cancel(id: CancelID.fetchQuickSearchWords)

            case .fetchQuickSearchWords:
                state.loadingState = .loading
                return .run { send in
                    let quickSearchWords = await databaseClient.fetchQuickSearchWords()
                    await send(.fetchQuickSearchWordsDone(quickSearchWords))
                }
                .cancellable(id: CancelID.fetchQuickSearchWords)

            case .fetchQuickSearchWordsDone(let words):
                state.loadingState = .idle
                // Clean invalid legacy records that were persisted before validation existed.
                let validWords = words.map(\.trimmed).filter(\.isValid)
                state.quickSearchWords = validWords
                return validWords.count == words.count ? .none : .send(.syncQuickSearchWords)
            }
        }
    }
}

extension QuickSearchWord {
    var trimmed: Self {
        .init(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    /// A quick-search record is only meaningful when it carries a searchable content string.
    var isValid: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
