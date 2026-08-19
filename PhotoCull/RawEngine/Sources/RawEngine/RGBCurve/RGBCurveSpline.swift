import Foundation

/// Monotone cubic Hermite spline, ported from darktable's `common/curve_tools.c`:
/// `monotone_hermite_set()` computes the Fritsch–Carlson-constrained tangents, and
/// `catmull_rom_val()` evaluates the per-segment Hermite basis given those tangents. (Despite
/// the name, darktable's `spline_val[]` table points `MONOTONE_HERMITE` at `catmull_rom_val` —
/// that function evaluates *any* cubic Hermite curve from a tangent array; monotonicity comes
/// entirely from how the tangents were constrained when computed, not from the evaluator.)
///
/// Values outside the node domain are flat-extrapolated (clamped to the nearest endpoint's y),
/// rather than porting darktable's `dt_iop_eval_exp` power-law extrapolation for out-of-gamut
/// HDR values: this curve sits after Filmic RGB + Color Balance RGB in this app's pipeline, both
/// of which already clip their output to roughly [0, 1], so values arriving here rarely if ever
/// leave the node domain in practice.
public struct RGBCurveSpline {
    /// Which of darktable's `curve_type` tangent formulas to use — the Hermite-basis evaluator
    /// (`evaluate`) is identical either way, per the type comment above; only tangent
    /// computation differs. `rgbcurve.c` defaults to `.monotoneHermite`; `colorzones.c` defaults
    /// to `.catmullRom`.
    public enum SplineType {
        case monotoneHermite
        case catmullRom
    }

    public let nodesX: [Double]
    public let nodesY: [Double]
    /// Exposed (not just used internally by `evaluate`) so `RGBCurveKernel` can pass the same
    /// precomputed tangents to the GPU instead of duplicating the Fritsch–Carlson derivation.
    public let tangents: [Double]

    /// `points` need not be pre-sorted; duplicate x values keep only the first occurrence.
    public init(points: [(x: Double, y: Double)], type: SplineType = .monotoneHermite) {
        var seenX = Set<Double>()
        let sorted = points.sorted { $0.x < $1.x }.filter { seenX.insert($0.x).inserted }
        nodesX = sorted.map(\.x)
        nodesY = sorted.map(\.y)
        switch type {
        case .monotoneHermite:
            tangents = Self.monotoneHermiteTangents(x: nodesX, y: nodesY)
        case .catmullRom:
            tangents = Self.catmullRomTangents(x: nodesX, y: nodesY)
        }
    }

    public func evaluate(_ xVal: Double) -> Double {
        let n = nodesX.count
        guard n >= 2 else { return nodesY.first ?? xVal }
        let clamped = min(max(xVal, nodesX[0]), nodesX[n - 1])

        var interval = n - 2
        for i in 0..<(n - 2) {
            if clamped < nodesX[i + 1] {
                interval = i
                break
            }
        }

        let x0 = nodesX[interval], x1 = nodesX[interval + 1]
        let y0 = nodesY[interval], y1 = nodesY[interval + 1]
        let m0 = tangents[interval], m1 = tangents[interval + 1]

        let h = x1 - x0
        let t = (clamped - x0) / h
        let t2 = t * t
        let t3 = t * t2

        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        return h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1
    }

    /// Ported from `monotone_hermite_set()`. `m` is sized `n + 1` in the original (the extra
    /// slot is written by the loop below but never read by `catmull_rom_val`, which only indexes
    /// up to `n - 1`); truncated to `n` before returning.
    private static func monotoneHermiteTangents(x: [Double], y: [Double]) -> [Double] {
        let n = x.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }

        var delta = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            delta[i] = (y[i + 1] - y[i]) / (x[i + 1] - x[i])
        }
        delta[n - 1] = delta[n - 2]

        var m = [Double](repeating: 0, count: n + 1)
        m[0] = delta[0]
        m[n - 1] = delta[n - 1]
        for i in 1..<(n - 1) {
            m[i] = (delta[i - 1] + delta[i]) * 0.5
        }

        let epsilon = 1e-12
        for i in 0..<n {
            if abs(delta[i]) < epsilon {
                m[i] = 0
                m[i + 1] = 0
            } else {
                let alpha = m[i] / delta[i]
                let beta = m[i + 1] / delta[i]
                let tau = alpha * alpha + beta * beta
                if tau > 9 {
                    let scale = 3 / tau.squareRoot()
                    m[i] = scale * alpha * delta[i]
                    m[i + 1] = scale * beta * delta[i]
                }
            }
        }
        return Array(m.prefix(n))
    }

    /// Ported from `catmull_rom_set()` in `common/curve_tools.c` — simple symmetric-difference
    /// tangents, no monotonicity constraint.
    private static func catmullRomTangents(x: [Double], y: [Double]) -> [Double] {
        let n = x.count
        guard n >= 2 else { return Array(repeating: 0, count: n) }

        var m = [Double](repeating: 0, count: n)
        m[0] = (y[1] - y[0]) / (x[1] - x[0])
        for i in 1..<(n - 1) {
            m[i] = (y[i + 1] - y[i - 1]) / (x[i + 1] - x[i - 1])
        }
        m[n - 1] = (y[n - 1] - y[n - 2]) / (x[n - 1] - x[n - 2])
        return m
    }
}
