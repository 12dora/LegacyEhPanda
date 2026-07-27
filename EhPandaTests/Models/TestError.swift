//
//  TestError.swift
//  EhPandaTests
//
//  Created by 荒木辰造 on R 4/02/11.
//

enum TestError: Error {
    case htmlDocumentNotFound(HTMLFilename)
}

extension TestError {
    var localizedDescription: String {
        switch self {
        case .htmlDocumentNotFound(let filename):
            return "HTML document \(filename.rawValue) not found."
        }
    }
}
