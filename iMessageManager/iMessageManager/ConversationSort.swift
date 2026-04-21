import Foundation

enum ConversationSort: String, CaseIterable, Identifiable {
    case latest
    case earliest
    case name
    case mostMessages

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .latest:
            return "Latest"
        case .earliest:
            return "Earliest"
        case .name:
            return "Name"
        case .mostMessages:
            return "Most Messages"
        }
    }
}
