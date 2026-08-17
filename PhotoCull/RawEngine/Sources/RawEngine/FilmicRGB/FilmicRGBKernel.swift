import CoreImage
import Foundation

/// Applies the filmic RGB tone curve to a `CIImage` via a custom `CIColorKernel`, evaluating
/// the same per-pixel formula as darktable's `filmic_split_v2_v3()` (log tone-mapping →
/// luminance-based desaturation → spline S-curve per channel → display power). See
/// `FilmicRGBParameters` for the scope note on which of darktable's chrominance-preservation
/// methods this corresponds to.
enum FilmicRGBKernel {
    /// Core Image Kernel Language source. Runtime-compiled by Core Image — no Xcode Metal
    /// build phase required, which keeps this buildable from a plain SwiftPM package.
    private static let source = """
    float filmicEval(
        float x,
        vec4 toeABCD, float toeE, float toeType,
        vec4 shoulderABCD, float shoulderE, float shoulderType,
        vec2 midAB,
        float latitudeMin, float latitudeMax)
    {
        if (x < latitudeMin) {
            if (toeType < 0.5) {
                // poly4: M1 + x(M2 + x(M3 + x(M4 + x*M5)))
                return toeABCD.x + x * (toeABCD.y + x * (toeABCD.z + x * (toeABCD.w + x * toeE)));
            } else if (toeType < 1.5) {
                // poly3: M1 + x(M2 + x(M3 + x*M4))
                return toeABCD.x + x * (toeABCD.y + x * (toeABCD.z + x * toeABCD.w));
            } else {
                // rational: M4 - M1 * rat / (rat + M3), rat = xi*(xi*M2 + 1), xi = latMin - x
                float xi = latitudeMin - x;
                float rat = xi * (xi * toeABCD.y + 1.0);
                return toeABCD.w - toeABCD.x * rat / (rat + toeABCD.z);
            }
        } else if (x > latitudeMax) {
            if (shoulderType < 0.5) {
                return shoulderABCD.x + x * (shoulderABCD.y + x * (shoulderABCD.z + x * (shoulderABCD.w + x * shoulderE)));
            } else if (shoulderType < 1.5) {
                return shoulderABCD.x + x * (shoulderABCD.y + x * (shoulderABCD.z + x * shoulderABCD.w));
            } else {
                float xi = x - latitudeMax;
                float rat = xi * (xi * shoulderABCD.y + 1.0);
                return shoulderABCD.w + shoulderABCD.x * rat / (rat + shoulderABCD.z);
            }
        } else {
            return midAB.x + x * midAB.y;
        }
    }

    kernel vec4 filmicRGB(
        sampler image,
        float greySource, float blackSource, float dynamicRange,
        float sigmaToe, float sigmaShoulder, float saturation,
        vec4 toeABCD, float toeE, float toeType,
        vec4 shoulderABCD, float shoulderE, float shoulderType,
        vec2 midAB,
        float latitudeMin, float latitudeMax,
        float outputPower)
    {
        vec4 pix = sample(image, samplerCoord(image));
        vec3 c = max(pix.rgb, vec3(0.0000152587890625));
        vec3 scaled = c / greySource;
        vec3 logv = vec3(log(scaled.x), log(scaled.y), log(scaled.z)) * 1.4426950408889634;
        vec3 mapped = clamp((logv - blackSource) / dynamicRange, 0.0, 1.0);

        float lum = dot(mapped, vec3(0.2225045, 0.7168786, 0.0606169));
        float radiusToe = lum;
        float radiusShoulder = 1.0 - lum;
        float sat2 = 0.5 / sqrt(saturation);
        float keyToe = exp(-radiusToe * radiusToe / sigmaToe * sat2);
        float keyShoulder = exp(-radiusShoulder * radiusShoulder / sigmaShoulder * sat2);
        float desat = saturation - (keyToe + keyShoulder) * saturation;

        vec3 sat = lum + desat * (mapped - lum);

        vec3 outc;
        outc.x = filmicEval(sat.x, toeABCD, toeE, toeType, shoulderABCD, shoulderE, shoulderType, midAB, latitudeMin, latitudeMax);
        outc.y = filmicEval(sat.y, toeABCD, toeE, toeType, shoulderABCD, shoulderE, shoulderType, midAB, latitudeMin, latitudeMax);
        outc.z = filmicEval(sat.z, toeABCD, toeE, toeType, shoulderABCD, shoulderE, shoulderType, midAB, latitudeMin, latitudeMax);

        outc = clamp(outc, 0.0, 1.0);
        outc = pow(outc, vec3(outputPower));
        return vec4(outc, pix.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        CIColorKernel(source: source)
    }()

    /// Renders `image` through the filmic RGB curve. Returns `image` unchanged if the kernel
    /// failed to compile (should not happen at runtime; guarded rather than force-unwrapped so
    /// a malformed kernel degrades to a no-op instead of crashing the live preview).
    static func apply(to image: CIImage, params: FilmicRGBParameters) -> CIImage {
        guard let kernel else { return image }
        let spline = FilmicSpline.compute(params)

        let blackSource = params.blackPointSource
        let dynamicRange = params.whitePointSource - blackSource
        let saturationCoefficient = 2.0 * params.saturation / 100.0 + 1.0

        let arguments: [Any] = [
            image,
            Float(0.1845), // grey_source, in [0,1]: darktable's fixed 18.45% grey (custom_grey == false)
            Float(blackSource),
            Float(dynamicRange),
            Float(spline.sigmaToe),
            Float(spline.sigmaShoulder),
            Float(saturationCoefficient),
            CIVector(x: CGFloat(spline.m1Toe), y: CGFloat(spline.m2Toe), z: CGFloat(spline.m3Toe), w: CGFloat(spline.m4Toe)),
            Float(spline.m5Toe),
            Float(spline.toeType.rawValue),
            CIVector(x: CGFloat(spline.m1Shoulder), y: CGFloat(spline.m2Shoulder), z: CGFloat(spline.m3Shoulder), w: CGFloat(spline.m4Shoulder)),
            Float(spline.m5Shoulder),
            Float(spline.shoulderType.rawValue),
            CIVector(x: CGFloat(spline.m1Mid), y: CGFloat(spline.m2Mid)),
            Float(spline.latitudeMin),
            Float(spline.latitudeMax),
            Float(params.outputPower)
        ]

        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }
}
