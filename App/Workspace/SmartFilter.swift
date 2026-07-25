import Foundation

/// Sidebar smart queues (Revu smart filters, Melingo-shaped).
enum SmartFilter: String, CaseIterable, Identifiable, Hashable {
    case due
    case new
    case weak
    case suspended

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .due: "smart.due"
        case .new: "smart.new"
        case .weak: "smart.weak"
        case .suspended: "smart.suspended"
        }
    }

    var systemImage: String {
        switch self {
        case .due: "clock.badge.exclamationmark"
        case .new: "sparkles"
        case .weak: "brain.head.profile"
        case .suspended: "pause.circle"
        }
    }
}
