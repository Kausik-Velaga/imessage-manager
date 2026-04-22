import Foundation

enum RelationshipCategory: String, CaseIterable, Identifiable {
    case closeFriend
    case friend
    case family
    case acquaintance
    case professional
    case transactional
    case group
    case unknown

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .closeFriend:
            return "Close Friend"
        case .friend:
            return "Friend"
        case .family:
            return "Family"
        case .acquaintance:
            return "Acquaintance"
        case .professional:
            return "Professional"
        case .transactional:
            return "Transactional"
        case .group:
            return "Group"
        case .unknown:
            return "Unknown"
        }
    }

    static var llmCategoryDescriptions: String {
        allCases
            .map { "- \($0.rawValue): \($0.displayName)" }
            .joined(separator: "\n")
    }
}
