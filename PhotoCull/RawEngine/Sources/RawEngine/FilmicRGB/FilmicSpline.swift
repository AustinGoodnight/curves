import Foundation

/// Coefficients for the 3-segment (toe / linear latitude / shoulder) filmic curve, derived once
/// per parameter change — the expensive part is this fit, not evaluating the resulting spline.
/// Mirrors `dt_iop_filmic_rgb_spline_t` from `filmicrgb.c`.
struct FilmicSplineCoefficients: Equatable {
    // Toe segment (index 0), shoulder segment (index 1): up to 5 polynomial coefficients each
    // (M5 is only used for `.poly4`). Linear-latitude segment (index 2): M1 = intercept, M2 = slope.
    var m1Toe = 0.0, m2Toe = 0.0, m3Toe = 0.0, m4Toe = 0.0, m5Toe = 0.0
    var m1Shoulder = 0.0, m2Shoulder = 0.0, m3Shoulder = 0.0, m4Shoulder = 0.0, m5Shoulder = 0.0
    var m1Mid = 0.0, m2Mid = 0.0

    var latitudeMin = 0.0
    var latitudeMax = 0.0

    var toeType: FilmicCurveType = .poly4
    var shoulderType: FilmicCurveType = .poly4

    var sigmaToe = 0.0
    var sigmaShoulder = 0.0
}

enum FilmicSpline {
    private static let safetyMargin = 0.01

    /// Port of `dt_iop_filmic_rgb_compute_spline()`, restricted to `spline_version >= V3`
    /// (darktable's shipped default since the 2021 release) and `custom_grey == false`
    /// (18.45%-grey convention) — see the scope note on `FilmicRGBParameters`.
    static func compute(_ p: FilmicRGBParameters) -> FilmicSplineCoefficients {
        var spline = FilmicSplineCoefficients()

        let greyDisplay = pow(0.1845, 1.0 / p.outputPower)

        let whiteSource = p.whitePointSource
        let blackSource = p.blackPointSource
        let dynamicRange = whiteSource - blackSource

        let blackLog = 0.0
        let greyLog = abs(blackSource) / dynamicRange
        let whiteLog = 1.0

        let blackDisplay = pow(clampValue(p.blackPointTarget, 0, p.greyPointTarget) / 100.0, 1.0 / p.outputPower)
        let whiteDisplay = pow(max(p.whitePointTarget, p.greyPointTarget) / 100.0, 1.0 / p.outputPower)

        let hardness = p.outputPower
        let latitude = clampValue(p.latitude, 0, 100) / 100.0
        let slope = p.contrast * dynamicRange / 8.0

        var minContrast = 1.0
        minContrast = max(minContrast, (whiteDisplay - greyDisplay) / (whiteLog - greyLog))
        minContrast = max(minContrast, (greyDisplay - blackDisplay) / (greyLog - blackLog))
        minContrast += safetyMargin

        var contrast = slope / (hardness * pow(greyDisplay, hardness - 1.0))
        contrast = clampValue(contrast, minContrast, 100.0)

        let linearIntercept = greyDisplay - contrast * greyLog

        let xmin = (blackDisplay + safetyMargin * (whiteDisplay - blackDisplay) - linearIntercept) / contrast
        let xmax = (whiteDisplay - safetyMargin * (whiteDisplay - blackDisplay) - linearIntercept) / contrast

        var toeLog = (1.0 - latitude) * greyLog + latitude * xmin
        var shoulderLog = (1.0 - latitude) * greyLog + latitude * xmax

        let balance = clampValue(p.balance, -50, 50) / 100.0
        let balanceCorrection = balance > 0
            ? 2.0 * balance * (shoulderLog - greyLog)
            : 2.0 * balance * (greyLog - toeLog)
        toeLog -= balanceCorrection
        shoulderLog -= balanceCorrection
        toeLog = max(toeLog, xmin)
        shoulderLog = min(shoulderLog, xmax)

        let toeDisplay = toeLog * contrast + linearIntercept
        let shoulderDisplay = shoulderLog * contrast + linearIntercept

        let x = [blackLog, toeLog, greyLog, shoulderLog, whiteLog]
        let y = [blackDisplay, toeDisplay, greyDisplay, shoulderDisplay, whiteDisplay]

        spline.latitudeMin = x[1]
        spline.latitudeMax = x[3]
        spline.toeType = p.shadowsCurve
        spline.shoulderType = p.highlightsCurve

        // Linear latitude segment: y = m1Mid + m2Mid * x
        spline.m2Mid = contrast
        spline.m1Mid = y[1] - spline.m2Mid * x[1]

        let tl = x[1], sl = x[3]

        switch p.shadowsCurve {
        case .poly4:
            let tl2 = tl * tl, tl3 = tl2 * tl, tl4 = tl3 * tl
            let a0: [Double] = [
                0, 0, 0, 0, 1,
                0, 0, 0, 1, 0,
                tl4, tl3, tl2, tl, 1,
                4 * tl3, 3 * tl2, 2 * tl, 1, 0,
                12 * tl2, 6 * tl, 2, 0, 0
            ]
            let b0 = gaussSolve(a0, [y[0], 0, y[1], spline.m2Mid, 0], 5)
            spline.m5Toe = b0[0]; spline.m4Toe = b0[1]; spline.m3Toe = b0[2]
            spline.m2Toe = b0[3]; spline.m1Toe = b0[4]
        case .poly3:
            let tl2 = tl * tl, tl3 = tl2 * tl
            let a0: [Double] = [
                0, 0, 0, 1,
                tl3, tl2, tl, 1,
                3 * tl2, 2 * tl, 1, 0,
                6 * tl, 2, 0, 0
            ]
            let b0 = gaussSolve(a0, [y[0], y[1], spline.m2Mid, 0], 4)
            spline.m5Toe = 0; spline.m4Toe = b0[0]; spline.m3Toe = b0[1]
            spline.m2Toe = b0[2]; spline.m1Toe = b0[3]
        case .rational:
            let dx = tl - x[0]
            let dy = y[1] - y[0]
            let g = contrast
            let b = g / (2 * dy) + (sqrt(sqf(dx * g / dy + 1) - 4) - 1) / (2 * dx)
            let c = dy / g * (b * sqf(dx) + dx) / (b * sqf(dx) + dx - (dy / g))
            let a = c * g
            spline.m1Toe = a; spline.m2Toe = b; spline.m3Toe = c; spline.m4Toe = toeDisplay
        }

        switch p.highlightsCurve {
        case .poly4:
            let sl2 = sl * sl, sl3 = sl2 * sl, sl4 = sl3 * sl
            let a1: [Double] = [
                1, 1, 1, 1, 1,
                4, 3, 2, 1, 0,
                sl4, sl3, sl2, sl, 1,
                4 * sl3, 3 * sl2, 2 * sl, 1, 0,
                12 * sl2, 6 * sl, 2, 0, 0
            ]
            let b1 = gaussSolve(a1, [y[4], 0, y[3], spline.m2Mid, 0], 5)
            spline.m5Shoulder = b1[0]; spline.m4Shoulder = b1[1]; spline.m3Shoulder = b1[2]
            spline.m2Shoulder = b1[3]; spline.m1Shoulder = b1[4]
        case .poly3:
            let sl2 = sl * sl, sl3 = sl2 * sl
            let a1: [Double] = [
                1, 1, 1, 1,
                sl3, sl2, sl, 1,
                3 * sl2, 2 * sl, 1, 0,
                6 * sl, 2, 0, 0
            ]
            let b1 = gaussSolve(a1, [y[4], y[3], spline.m2Mid, 0], 4)
            spline.m5Shoulder = 0; spline.m4Shoulder = b1[0]; spline.m3Shoulder = b1[1]
            spline.m2Shoulder = b1[2]; spline.m1Shoulder = b1[3]
        case .rational:
            let dx = x[4] - sl
            let dy = y[4] - y[3]
            let g = contrast
            let b = g / (2 * dy) + (sqrt(sqf(dx * g / dy + 1) - 4) - 1) / (2 * dx)
            let c = dy / g * (b * sqf(dx) + dx) / (b * sqf(dx) + dx - (dy / g))
            let a = c * g
            spline.m1Shoulder = a; spline.m2Shoulder = b; spline.m3Shoulder = c; spline.m4Shoulder = shoulderDisplay
        }

        spline.sigmaToe = pow(spline.latitudeMin / 3.0, 2.0)
        spline.sigmaShoulder = pow((1.0 - spline.latitudeMax) / 3.0, 2.0)

        return spline
    }

    /// Evaluates the fitted spline at `x` — a Swift-side reference implementation of
    /// `filmic_spline()`, used by tests and by the darktable-cli comparison harness. The live
    /// preview path evaluates the same formula per-pixel on the GPU (`FilmicRGBKernel`).
    static func evaluate(_ x: Double, _ s: FilmicSplineCoefficients) -> Double {
        if x < s.latitudeMin {
            switch s.toeType {
            case .poly4:
                return s.m1Toe + x * (s.m2Toe + x * (s.m3Toe + x * (s.m4Toe + x * s.m5Toe)))
            case .poly3:
                return s.m1Toe + x * (s.m2Toe + x * (s.m3Toe + x * s.m4Toe))
            case .rational:
                let xi = s.latitudeMin - x
                let rat = xi * (xi * s.m2Toe + 1)
                return s.m4Toe - s.m1Toe * rat / (rat + s.m3Toe)
            }
        } else if x > s.latitudeMax {
            switch s.shoulderType {
            case .poly4:
                return s.m1Shoulder + x * (s.m2Shoulder + x * (s.m3Shoulder + x * (s.m4Shoulder + x * s.m5Shoulder)))
            case .poly3:
                return s.m1Shoulder + x * (s.m2Shoulder + x * (s.m3Shoulder + x * s.m4Shoulder))
            case .rational:
                let xi = x - s.latitudeMax
                let rat = xi * (xi * s.m2Shoulder + 1)
                return s.m4Shoulder + s.m1Shoulder * rat / (rat + s.m3Shoulder)
            }
        } else {
            return s.m1Mid + x * s.m2Mid
        }
    }
}

private func sqf(_ x: Double) -> Double { x * x }

private func clampValue(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}

/// Standard Gaussian elimination with partial pivoting, solving `A x = b` for a dense n×n
/// system. `a` is row-major. This is generic linear algebra, not darktable-specific code —
/// darktable's own `gauss_solve()` (`src/iop/gaussian_elimination.h`) solves the same
/// well-conditioned system these polynomial-fit constraints always produce, so any correct
/// solver converges to the same coefficients.
func gaussSolve(_ aFlat: [Double], _ bIn: [Double], _ n: Int) -> [Double] {
    var a = aFlat
    var x = bIn

    for i in 0..<n {
        var maxRow = i
        var maxVal = abs(a[i * n + i])
        for r in (i + 1)..<n {
            let v = abs(a[r * n + i])
            if v > maxVal { maxVal = v; maxRow = r }
        }
        if maxRow != i {
            for c in 0..<n { a.swapAt(i * n + c, maxRow * n + c) }
            x.swapAt(i, maxRow)
        }
        let pivot = a[i * n + i]
        guard pivot != 0 else { continue }
        for r in (i + 1)..<n {
            let factor = a[r * n + i] / pivot
            guard factor != 0 else { continue }
            for c in i..<n { a[r * n + c] -= factor * a[i * n + c] }
            x[r] -= factor * x[i]
        }
    }

    var solution = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var sum = x[i]
        for c in (i + 1)..<n { sum -= a[i * n + c] * solution[c] }
        solution[i] = a[i * n + i] == 0 ? 0 : sum / a[i * n + i]
    }
    return solution
}
