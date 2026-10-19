import Foundation

/// CIE Lab <-> XYZ, standard formulas (CIE 1976). Reuses `ColorBalanceMath.rgbToXYZ`/`xyzToRGB`
/// (`ColorBalanceRGBMath.swift`) for the RGB<->XYZ leg — both already assume linear sRGB/Rec709
/// at D65, so the white point used here is D65 too, keeping the whole chain internally
/// consistent rather than mixing in darktable's D50-referenced Lab.
enum ColorZonesMath {
    // CIE 1931 2° D65 white point.
    private static let whiteX = 0.95047
    private static let whiteY = 1.00000
    private static let whiteZ = 1.08883

    private static let delta = 6.0 / 29.0

    private static func f(_ t: Double) -> Double {
        t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29.0
    }

    private static func fInverse(_ t: Double) -> Double {
        t > delta ? t * t * t : 3 * delta * delta * (t - 4.0 / 29.0)
    }

    static func xyzToLab(_ xyz: Triplet) -> Triplet {
        let fx = f(xyz.x / whiteX)
        let fy = f(xyz.y / whiteY)
        let fz = f(xyz.z / whiteZ)
        return Triplet(x: 116 * fy - 16, y: 500 * (fx - fy), z: 200 * (fy - fz))
    }

    static func labToXYZ(_ lab: Triplet) -> Triplet {
        let fy = (lab.x + 16) / 116
        let fx = fy + lab.y / 500
        let fz = fy - lab.z / 200
        return Triplet(x: whiteX * fInverse(fx), y: whiteY * fInverse(fy), z: whiteZ * fInverse(fz))
    }

    static func rgbToLab(_ rgb: Triplet) -> Triplet {
        xyzToLab(ColorBalanceMath.rgbToXYZ(rgb))
    }

    static func labToRGB(_ lab: Triplet) -> Triplet {
        ColorBalanceMath.xyzToRGB(labToXYZ(lab))
    }
}
