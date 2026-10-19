import Foundation

/// Parameters for the dehaze module — a single-pass dark-channel-prior haze removal (He, Sun &
/// Tang, "Single Image Haze Removal Using Dark Channel Prior", 2009), not a port of a specific
/// darktable module the way the other stackable modules are. `amount` is the removal strength
/// (0 = no-op, 1 = maximum); there's no user-facing atmospheric-light estimate — see
/// `DehazeKernel`'s doc comment for why a fixed near-white assumption is good enough for a single
/// slider.
public struct DehazeParameters: Equatable, Sendable {
    public var amount: Double

    public init(amount: Double = 0) {
        self.amount = amount
    }

    public static let none = DehazeParameters()
}
