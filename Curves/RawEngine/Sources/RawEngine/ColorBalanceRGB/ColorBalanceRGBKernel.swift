import CoreImage
import Foundation

/// Applies the color balance RGB "wheels" to a `CIImage` via a custom `CIColorKernel`,
/// evaluating the same per-pixel formula as `ColorBalanceRGBProcessor.apply` (the Swift
/// reference this was transcribed from — see that file for the full pipeline breakdown and
/// `ColorBalanceRGBParameters` for the scope note on what's omitted from darktable's module).
enum ColorBalanceRGBKernel {
    private static let source = """
    const float D65_R = 0.21902143;
    const float D65_G = 0.54371398;
    const float MASK_LUMA_EXPONENT = 0.4101205819200422;

    vec3 cbRGBToXYZ(vec3 rgb)
    {
        return vec3(
            0.4124564 * rgb.x + 0.3575761 * rgb.y + 0.1804375 * rgb.z,
            0.2126729 * rgb.x + 0.7151522 * rgb.y + 0.0721750 * rgb.z,
            0.0193339 * rgb.x + 0.1191920 * rgb.y + 0.9503041 * rgb.z);
    }

    vec3 cbXYZToRGB(vec3 xyz)
    {
        return vec3(
             3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
            -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
             0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z);
    }

    vec3 cbXYZToLMS(vec3 xyz)
    {
        return vec3(
             0.257085 * xyz.x + 0.859943 * xyz.y - 0.031061 * xyz.z,
            -0.394427 * xyz.x + 1.175800 * xyz.y + 0.106423 * xyz.z,
             0.064856 * xyz.x - 0.076250 * xyz.y + 0.559067 * xyz.z);
    }

    vec3 cbLMSToXYZ(vec3 lms)
    {
        return vec3(
             1.80794659 * lms.x - 1.29971660 * lms.y + 0.34785879 * lms.z,
             0.61783960 * lms.x + 0.39595453 * lms.y - 0.04104687 * lms.z,
            -0.12546960 * lms.x + 0.20478038 * lms.y + 1.74274183 * lms.z);
    }

    vec3 cbGradingRGBToLMS(vec3 rgb)
    {
        return vec3(
            0.95 * rgb.x + 0.38 * rgb.y,
            0.05 * rgb.x + 0.62 * rgb.y + 0.03 * rgb.z,
            0.97 * rgb.z);
    }

    vec3 cbLMSToGradingRGB(vec3 lms)
    {
        return vec3(
             1.08771930 * lms.x - 0.66666667 * lms.y + 0.02061856 * lms.z,
            -0.0877193  * lms.x + 1.66666667 * lms.y - 0.05154639 * lms.z,
             1.03092784 * lms.z);
    }

    vec3 cbLMSToYrg(vec3 lms)
    {
        float Y = 0.68990272 * lms.x + 0.34832189 * lms.y;
        float a = lms.x + lms.y + lms.z;
        vec3 normalized = (a == 0.0) ? vec3(0.0) : lms / a;
        vec3 rgb = cbLMSToGradingRGB(normalized);
        return vec3(Y, rgb.x, rgb.y);
    }

    vec3 cbYrgToLMS(vec3 yrg)
    {
        float b = 1.0 - yrg.y - yrg.z;
        vec3 lms = cbGradingRGBToLMS(vec3(yrg.y, yrg.z, b));
        float denom = 0.68990272 * lms.x + 0.34832189 * lms.y;
        float a = (denom == 0.0) ? 0.0 : yrg.x / denom;
        return lms * a;
    }

    // Ych stored as vec4(Y, chroma, cos_h, sin_h), matching the Swift reference.
    vec4 cbYrgToYch(vec3 yrg)
    {
        float r = yrg.y - D65_R;
        float g = yrg.z - D65_G;
        float c = sqrt(r * r + g * g);
        float cosH = (c != 0.0) ? r / c : 1.0;
        float sinH = (c != 0.0) ? g / c : 0.0;
        return vec4(yrg.x, c, cosH, sinH);
    }

    vec3 cbYchToYrg(vec4 ych)
    {
        return vec3(ych.x, ych.y * ych.z + D65_R, ych.y * ych.w + D65_G);
    }

    vec3 cbYchToGradingRGB(vec4 ych)
    {
        return cbLMSToGradingRGB(cbYrgToLMS(cbYchToYrg(ych)));
    }

    vec4 cbGamutCheckYrg(vec4 ych)
    {
        vec3 yrg = cbYchToYrg(ych);
        float maxC = ych.y;
        if (yrg.y < 0.0) { maxC = min(-D65_R / ych.z, maxC); }
        if (yrg.z < 0.0) { maxC = min(-D65_G / ych.w, maxC); }
        if (yrg.y + yrg.z > 1.0) { maxC = min((1.0 - D65_R - D65_G) / (ych.z + ych.w), maxC); }
        return vec4(ych.x, maxC, ych.z, ych.w);
    }

    // Returns (shadow, midtone, highlight) opacities.
    vec3 cbOpacityMasks(float x, float shadowsWeight, float highlightsWeight, float midtonesWeight, float maskGreyFulcrum)
    {
        float xOffset = x - maskGreyFulcrum;
        float xOffsetNorm = xOffset / maskGreyFulcrum;
        float alpha = 1.0 / (1.0 + exp(xOffsetNorm * shadowsWeight));
        float beta = 1.0 / (1.0 + exp(-xOffsetNorm * highlightsWeight));
        float alphaComp = 1.0 - alpha;
        float betaComp = 1.0 - beta;
        float gamma = exp(-xOffset * xOffset * midtonesWeight / 4.0) * alphaComp * alphaComp * betaComp * betaComp * 8.0;
        return vec3(alpha, gamma, beta);
    }

    kernel vec4 colorBalanceRGB(
        sampler image,
        vec3 gGlobal, vec3 gShadows, vec3 gHighlights, vec3 gMidtones,
        float midtonesY, float shadowsWeight, float highlightsWeight, float midtonesWeight,
        float maskGreyFulcrum, float whiteFulcrum, float greyFulcrum, float contrastAmt,
        float chromaGlobal, float chromaShadows, float chromaMidtones, float chromaHighlights,
        float vibrance, float hueAngle)
    {
        vec4 pix = sample(image, samplerCoord(image));
        vec3 rgb = max(pix.rgb, vec3(0.0));

        vec3 xyz = cbRGBToXYZ(rgb);
        vec3 lms = cbXYZToLMS(xyz);
        vec3 yrg = cbLMSToYrg(lms);
        vec4 ych = cbYrgToYch(yrg);
        ych.x = max(ych.x, 0.0);

        vec3 opac = cbOpacityMasks(pow(ych.x, MASK_LUMA_EXPONENT), shadowsWeight, highlightsWeight, midtonesWeight, maskGreyFulcrum);
        vec3 opacComp = vec3(1.0) - opac;

        float cosA = cos(hueAngle);
        float sinA = sin(hueAngle);
        float cosH = ych.z;
        float sinH = ych.w;
        ych.z = cosA * cosH - sinA * sinH;
        ych.w = sinA * cosH + cosA * sinH;

        float chromaBoost = chromaGlobal + opac.x * chromaShadows + opac.y * chromaMidtones + opac.z * chromaHighlights;
        float vib = vibrance * (1.0 - pow(ych.y, abs(vibrance)));
        float chromaFactor = max(1.0 + chromaBoost + vib, 0.0);
        ych.y *= chromaFactor;
        ych = cbGamutCheckYrg(ych);

        vec3 gradingRGB = cbYchToGradingRGB(ych);
        gradingRGB = gradingRGB + gGlobal;

        float bx = opacComp.z * (opacComp.x + opac.x * gShadows.x) + opac.z * gHighlights.x;
        float by = opacComp.z * (opacComp.x + opac.x * gShadows.y) + opac.z * gHighlights.y;
        float bz = opacComp.z * (opacComp.x + opac.x * gShadows.z) + opac.z * gHighlights.z;
        gradingRGB = gradingRGB * vec3(bx, by, bz);

        vec3 signv = vec3(
            gradingRGB.x < 0.0 ? -1.0 : 1.0,
            gradingRGB.y < 0.0 ? -1.0 : 1.0,
            gradingRGB.z < 0.0 ? -1.0 : 1.0);
        vec3 scaled = abs(gradingRGB) / whiteFulcrum;
        vec3 powered = vec3(pow(scaled.x, gMidtones.x), pow(scaled.y, gMidtones.y), pow(scaled.z, gMidtones.z));
        gradingRGB = powered * signv * whiteFulcrum;

        vec3 lms2 = cbGradingRGBToLMS(gradingRGB);
        vec3 yrg2 = cbLMSToYrg(lms2);

        yrg2.x = pow(max(yrg2.x / whiteFulcrum, 0.0), midtonesY) * whiteFulcrum;
        yrg2.x = greyFulcrum * pow(yrg2.x / greyFulcrum, contrastAmt);

        vec3 lms3 = cbYrgToLMS(yrg2);
        vec3 xyzOut = cbLMSToXYZ(lms3);
        vec3 rgbOut = cbXYZToRGB(xyzOut);
        rgbOut = max(rgbOut, vec3(0.0));

        return vec4(rgbOut, pix.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        CIColorKernel(source: source)
    }()

    static func apply(to image: CIImage, params: ColorBalanceRGBParameters) -> CIImage {
        guard let kernel else { return image }
        let d = ColorBalanceRGBProcessor.compute(params)

        let arguments: [Any] = [
            image,
            CIVector(x: CGFloat(d.global.x), y: CGFloat(d.global.y), z: CGFloat(d.global.z)),
            CIVector(x: CGFloat(d.shadows.x), y: CGFloat(d.shadows.y), z: CGFloat(d.shadows.z)),
            CIVector(x: CGFloat(d.highlights.x), y: CGFloat(d.highlights.y), z: CGFloat(d.highlights.z)),
            CIVector(x: CGFloat(d.midtones.x), y: CGFloat(d.midtones.y), z: CGFloat(d.midtones.z)),
            Float(d.midtonesY),
            Float(d.shadowsWeight),
            Float(d.highlightsWeight),
            Float(d.midtonesWeight),
            Float(d.maskGreyFulcrum),
            Float(d.whiteFulcrum),
            Float(d.greyFulcrum),
            Float(d.contrast),
            Float(d.chromaGlobal),
            Float(d.chromaShadows),
            Float(d.chromaMidtones),
            Float(d.chromaHighlights),
            Float(d.vibrance),
            Float(d.hueAngle)
        ]

        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }
}
