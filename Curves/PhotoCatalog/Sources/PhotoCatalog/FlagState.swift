import Foundation

public enum FlagState: Int, Codable, CaseIterable, Hashable, Sendable {
    case none = 0
    case pick = 1
    case reject = 2
}
