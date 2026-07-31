import TDLibKit

/// TDLib's client type is a class; mark it unchecked-Sendable for Melingo call sites.
extension TDLibClient: @unchecked @retroactive Sendable {}
