import CoreImage
import Foundation

/// Applies the AgX tone mapper to a `CIImage` via a custom `CIColorKernel`, evaluating the same
/// per-pixel formula as darktable's `agx.c` `process()`/`_agx_tone_mapping()`: pipe RGB → base
/// (Rec2020) RGB → gamut compression → "rendering" (inset+rotated) RGB → log2 encode → fitted
/// toe/linear/shoulder curve → Blender-style look (lift/slope/power/saturation) → gamma-linearize
/// → hue restore → back to pipe RGB. See `AgXParameters` for the scope note on what's fixed vs.
/// exposed, and `AgXCurve` for the curve-fit this evaluates.
enum AgXKernel {
    /// Core Image Kernel Language source. Runtime-compiled by Core Image, same as
    /// `FilmicRGBKernel`/`ColorBalanceRGBKernel` — no Xcode Metal build phase required.
    ///
    /// The three colorimetry matrices below (`agxPipeToBase`/`agxBaseToRendering`/
    /// `agxRenderingToPipe`) and the two luminance-weight vectors are fixed constants, not kernel
    /// arguments: with this engine's working space fixed at linear sRGB/Rec709 D65 (see
    /// `ColorBalanceRGBMath`'s doc comment) and AgX's primaries fixed at darktable's own
    /// "blenderlike" default (`AgXParameters`'s scope note), every one of these matrices is the
    /// same for every pixel and every parameter change — computed once by hand-porting
    /// `dt_rotate_and_scale_primary` + `dt_make_transposed_matrices_from_primaries_and_whitepoint`
    /// to Python and verifying the Rec709→Rec2020 leg against the well-known reference matrix.
    /// Hardcoding them here (rather than passing as kernel arguments) matches
    /// `ColorBalanceRGBKernel`'s own precedent for its fixed Rec709↔XYZ↔LMS matrices.
    private static let source = """
    vec3 agxPipeToBase(vec3 c) {
        return vec3(
            0.6274038959 * c.x + 0.3292830384 * c.y + 0.0433130657 * c.z,
            0.0690972894 * c.x + 0.9195403951 * c.y + 0.0113623156 * c.z,
            0.0163914389 * c.x + 0.0880133079 * c.y + 0.8955952532 * c.z);
    }

    vec3 agxBaseToRendering(vec3 c) {
        return vec3(
             1.1977722486 * c.x - 0.1318911715 * c.y - 0.0658810771 * c.z,
            -0.1714378422 * c.x + 1.3594583970 * c.y - 0.1880205547 * c.z,
            -0.1242713841 * c.x - 0.0970769636 * c.y + 1.2213483477 * c.z);
    }

    vec3 agxRenderingToPipe(vec3 c) {
        return vec3(
             1.4350380131 * c.x - 0.3927666840 * c.y - 0.0422713291 * c.z,
            -0.0025753804 * c.x + 0.9929001869 * c.y + 0.0096751935 * c.z,
             0.0831154295 * c.x - 0.0005028571 * c.y + 0.9173874276 * c.z);
    }

    vec3 agxCompressGamut(vec3 pixel) {
        vec3 lumaCoeffs = vec3(0.2658180370250449, 0.59846986045365, 0.1357121025213052);
        float inputY = dot(pixel, lumaCoeffs);
        float maxRGB = max(pixel.x, max(pixel.y, pixel.z));
        vec3 opponent = vec3(maxRGB) - pixel;
        float opponentY = dot(opponent, lumaCoeffs);
        float maxOpponent = max(opponent.x, max(opponent.y, opponent.z));
        float yCompensateNegative = maxOpponent - opponentY + inputY;

        float minRGB = min(pixel.x, min(pixel.y, pixel.z));
        float offset = max(-minRGB, 0.0);
        vec3 rgbOffset = pixel + vec3(offset);
        float maxOfRgbOffset = max(rgbOffset.x, max(rgbOffset.y, rgbOffset.z));
        vec3 opponentOffset = vec3(maxOfRgbOffset) - rgbOffset;
        float maxInverseRgbOffset = max(opponentOffset.x, max(opponentOffset.y, opponentOffset.z));
        float yInverseRgbOffset = dot(opponentOffset, lumaCoeffs);
        float yNew = dot(rgbOffset, lumaCoeffs);
        yNew = maxInverseRgbOffset - yInverseRgbOffset + yNew;

        float luminanceRatio = (yNew > yCompensateNegative && yNew > 0.000001) ? yCompensateNegative / yNew : 1.0;
        return luminanceRatio * rgbOffset;
    }

    float agxSigmoid(float x, float power) {
        return x / pow(1.0 + pow(x, power), 1.0 / power);
    }

    float agxScaledSigmoid(float x, float scale, float slope, float power, float transitionX, float transitionY) {
        return scale * agxSigmoid(slope * (x - transitionX) / scale, power) + transitionY;
    }

    float agxFallbackToe(float x, float targetBlack, float coeff, float power) {
        return x < 0.0 ? targetBlack : targetBlack + max(0.0, coeff * pow(x, power));
    }

    float agxFallbackShoulder(float x, float targetWhite, float coeff, float power) {
        return x >= 1.0 ? targetWhite : targetWhite - max(0.0, coeff * pow(1.0 - x, power));
    }

    // toeABCD/shoulderABCD = (transitionX, transitionY, scale, power); *Fallback = (isFallbackFlag, coeff, power, _)
    float agxApplyCurve(float x, vec4 curveMain, vec4 toeABCD, vec4 toeFallback, vec4 shoulderABCD, vec4 shoulderFallback) {
        float slope = curveMain.x;
        float result;
        if (x < toeABCD.x) {
            result = toeFallback.x > 0.5
                ? agxFallbackToe(x, curveMain.z, toeFallback.y, toeFallback.z)
                : agxScaledSigmoid(x, toeABCD.z, slope, toeABCD.w, toeABCD.x, toeABCD.y);
        } else if (x <= shoulderABCD.x) {
            result = slope * x + curveMain.y;
        } else {
            result = shoulderFallback.x > 0.5
                ? agxFallbackShoulder(x, curveMain.w, shoulderFallback.y, shoulderFallback.z)
                : agxScaledSigmoid(x, shoulderABCD.z, slope, shoulderABCD.w, shoulderABCD.x, shoulderABCD.y);
        }
        return clamp(result, curveMain.z, curveMain.w);
    }

    float agxApplyLogEncoding(float x, float rangeInEV, float blackRelativeEV) {
        float xRelative = max(0.0000009536743, x / 0.18);
        float mapped = (log2(max(xRelative, 0.0)) - blackRelativeEV) / rangeInEV;
        return clamp(mapped, 0.0, 1.0);
    }

    vec3 agxApplySlopeLift(vec3 x, float slope, float lift) {
        float m = slope / (1.0 + lift);
        float b = lift * m;
        return m * x + vec3(b);
    }

    vec3 agxLook(vec3 pixel, float lookSlope, float lookLift, float lookPower, float lookSaturation) {
        vec3 v = agxApplySlopeLift(pixel, lookSlope, lookLift);
        vec3 powered = vec3(
            v.x > 0.0 ? pow(v.x, lookPower) : v.x,
            v.y > 0.0 ? pow(v.y, lookPower) : v.y,
            v.z > 0.0 ? pow(v.z, lookPower) : v.z);
        vec3 renderingLuma = vec3(0.3119581342, 0.5395925370, 0.1484493288);
        float luma = dot(powered, renderingLuma);
        return luma + lookSaturation * (powered - luma);
    }

    // Matches darktable's dt_RGB_2_HSV/dt_HSV_2_RGB convention (hue wrapped to [0, 1)).
    float agxRGBToHue(vec3 rgb, float maxc, float delta) {
        float hue;
        if (rgb.x == maxc) hue = (rgb.y - rgb.z) / delta;
        else if (rgb.y == maxc) hue = 2.0 + (rgb.z - rgb.x) / delta;
        else hue = 4.0 + (rgb.x - rgb.y) / delta;
        hue /= 6.0;
        return hue - floor(hue);
    }

    vec3 agxRGBToHSV(vec3 rgb) {
        float minc = min(rgb.x, min(rgb.y, rgb.z));
        float maxc = max(rgb.x, max(rgb.y, rgb.z));
        float delta = maxc - minc;
        float h = 0.0;
        float s = 0.0;
        if (abs(maxc) > 0.000001 && abs(delta) > 0.000001) {
            s = delta / maxc;
            h = agxRGBToHue(rgb, maxc, delta);
        }
        return vec3(h, s, maxc);
    }

    vec3 agxHSVToRGB(vec3 hsv) {
        float c = hsv.y * hsv.z;
        float m = hsv.z - c;
        float h = hsv.x * 6.0;
        float i = floor(h);
        float f = h - i;
        float fc = f * c;
        float top = c + m;
        float inc = fc + m;
        float dec = top - fc;
        if (i < 0.5) return vec3(top, inc, m);
        else if (i < 1.5) return vec3(dec, top, m);
        else if (i < 2.5) return vec3(m, top, inc);
        else if (i < 3.5) return vec3(m, dec, top);
        else if (i < 4.5) return vec3(inc, m, top);
        else return vec3(top, m, dec);
    }

    float agxLerpHue(float original, float processed, float mix) {
        float d = processed - original;
        d = d - floor(d + 0.5);
        float mixed = (1.0 - mix) * d + original;
        return mixed - floor(mixed);
    }

    kernel vec4 agxToneMap(
        sampler image,
        vec2 logRange,
        vec4 curveMain,
        float curveGamma,
        vec4 toeABCD,
        vec4 toeFallback,
        vec4 shoulderABCD,
        vec4 shoulderFallback,
        vec4 look,
        vec4 lookExtra)
    {
        vec4 pix = sample(image, samplerCoord(image));
        vec3 rgb = clamp(pix.rgb, vec3(-1000000.0), vec3(1000000.0));

        vec3 baseRGB = agxPipeToBase(rgb);
        baseRGB = agxCompressGamut(baseRGB);
        vec3 renderingRGB = agxBaseToRendering(baseRGB);

        bool restoreHue = lookExtra.z > 0.5;
        float hBefore = restoreHue ? agxRGBToHSV(renderingRGB).x : 0.0;

        vec3 transformed;
        transformed.x = agxApplyCurve(agxApplyLogEncoding(renderingRGB.x, logRange.x, logRange.y), curveMain, toeABCD, toeFallback, shoulderABCD, shoulderFallback);
        transformed.y = agxApplyCurve(agxApplyLogEncoding(renderingRGB.y, logRange.x, logRange.y), curveMain, toeABCD, toeFallback, shoulderABCD, shoulderFallback);
        transformed.z = agxApplyCurve(agxApplyLogEncoding(renderingRGB.z, logRange.x, logRange.y), curveMain, toeABCD, toeFallback, shoulderABCD, shoulderFallback);

        if (lookExtra.y > 0.5) {
            transformed = agxLook(transformed, look.x, look.y, look.z, look.w);
        }

        transformed = pow(max(transformed, vec3(0.0)), vec3(curveGamma));

        vec3 outRendering;
        if (restoreHue) {
            vec3 hsvAfter = agxRGBToHSV(transformed);
            float hAfter = agxLerpHue(hBefore, hsvAfter.x, lookExtra.x);
            outRendering = agxHSVToRGB(vec3(hAfter, hsvAfter.y, hsvAfter.z));
        } else {
            outRendering = transformed;
        }

        vec3 outPipe = agxRenderingToPipe(outRendering);
        return vec4(outPipe, pix.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        CIColorKernel(source: source)
    }()

    /// Renders `image` through the AgX tone mapper. Returns `image` unchanged if the kernel
    /// failed to compile (should not happen at runtime; guarded rather than force-unwrapped so a
    /// malformed kernel degrades to a no-op instead of crashing the live preview).
    static func apply(to image: CIImage, params: AgXParameters) -> CIImage {
        guard let kernel else { return image }
        let c = AgXCurve.compute(params)

        let arguments: [Any] = [
            image,
            CIVector(x: CGFloat(c.rangeInEV), y: CGFloat(c.blackRelativeEV)),
            CIVector(x: CGFloat(c.slope), y: CGFloat(c.intercept), z: CGFloat(c.targetBlack), w: CGFloat(c.targetWhite)),
            Float(c.curveGamma),
            CIVector(x: CGFloat(c.toeTransitionX), y: CGFloat(c.toeTransitionY), z: CGFloat(c.toeScale), w: CGFloat(c.toePower)),
            CIVector(x: CGFloat(c.needConvexToe ? 1 : 0), y: CGFloat(c.toeFallbackCoefficient), z: CGFloat(c.toeFallbackPower), w: 0),
            CIVector(x: CGFloat(c.shoulderTransitionX), y: CGFloat(c.shoulderTransitionY), z: CGFloat(c.shoulderScale), w: CGFloat(c.shoulderPower)),
            CIVector(x: CGFloat(c.needConcaveShoulder ? 1 : 0), y: CGFloat(c.shoulderFallbackCoefficient), z: CGFloat(c.shoulderFallbackPower), w: 0),
            CIVector(x: CGFloat(c.lookSlope), y: CGFloat(c.lookLift), z: CGFloat(c.lookPower), w: CGFloat(c.lookSaturation)),
            CIVector(x: CGFloat(c.lookHueMixRatio), y: CGFloat(c.lookTuned ? 1 : 0), z: CGFloat(c.restoreHue ? 1 : 0), w: 0)
        ]

        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }
}
