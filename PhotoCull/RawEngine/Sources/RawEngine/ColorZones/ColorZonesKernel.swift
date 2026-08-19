import CoreImage
import Foundation

/// Applies the color zones EQ (lightness/chroma/hue vs. hue) to a `CIImage` via a custom
/// `CIColorKernel`, evaluating the same 3 Catmull-Rom curves as `ColorZonesParameters` and the
/// same formula as darktable's `process_v3()` in `colorzones.c`. See `ColorZonesParameters` for
/// the scope note on what this port covers.
public enum ColorZonesKernel {
    /// Same cap and packing scheme as `RGBCurveKernel` — see its doc comment for why (no dynamic
    /// array kernel arguments, so up to 8 points are packed as pairs of `vec4` per curve).
    public static let maxNodes = 8

    private static let source = """
    float pairAt(vec4 a, vec4 b, int i) {
        if (i == 0) return a.x;
        else if (i == 1) return a.y;
        else if (i == 2) return a.z;
        else if (i == 3) return a.w;
        else if (i == 4) return b.x;
        else if (i == 5) return b.y;
        else if (i == 6) return b.z;
        else return b.w;
    }

    float curveEval(
        float xIn,
        vec4 nodeX0, vec4 nodeX1,
        vec4 nodeY0, vec4 nodeY1,
        vec4 nodeM0, vec4 nodeM1,
        float nodeCountF)
    {
        int n = int(nodeCountF + 0.5);
        float xminV = pairAt(nodeX0, nodeX1, 0);
        float xmaxV = pairAt(nodeX0, nodeX1, n - 1);
        float x = clamp(xIn, xminV, xmaxV);

        int interval = n - 2;
        for (int i = 0; i < 6; i++) {
            if (i < n - 2 && x < pairAt(nodeX0, nodeX1, i + 1)) {
                interval = i;
                break;
            }
        }

        float x0 = pairAt(nodeX0, nodeX1, interval);
        float x1 = pairAt(nodeX0, nodeX1, interval + 1);
        float y0 = pairAt(nodeY0, nodeY1, interval);
        float y1 = pairAt(nodeY0, nodeY1, interval + 1);
        float m0 = pairAt(nodeM0, nodeM1, interval);
        float m1 = pairAt(nodeM0, nodeM1, interval + 1);

        float h = x1 - x0;
        float t = (x - x0) / h;
        float t2 = t * t;
        float t3 = t * t2;

        float h00 = 2.0 * t3 - 3.0 * t2 + 1.0;
        float h10 = t3 - 2.0 * t2 + t;
        float h01 = -2.0 * t3 + 3.0 * t2;
        float h11 = t3 - t2;

        return h00 * y0 + h10 * h * m0 + h01 * y1 + h11 * h * m1;
    }

    vec3 czRgbToXYZ(vec3 rgb) {
        return vec3(
            0.4124564 * rgb.x + 0.3575761 * rgb.y + 0.1804375 * rgb.z,
            0.2126729 * rgb.x + 0.7151522 * rgb.y + 0.0721750 * rgb.z,
            0.0193339 * rgb.x + 0.1191920 * rgb.y + 0.9503041 * rgb.z
        );
    }

    vec3 czXyzToRGB(vec3 xyz) {
        return vec3(
            3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
            -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
            0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z
        );
    }

    float czLabF(float t) {
        float d = 6.0 / 29.0;
        return t > d * d * d ? pow(t, 1.0 / 3.0) : t / (3.0 * d * d) + 4.0 / 29.0;
    }

    float czLabFInverse(float t) {
        float d = 6.0 / 29.0;
        return t > d ? t * t * t : 3.0 * d * d * (t - 4.0 / 29.0);
    }

    vec3 czXyzToLab(vec3 xyz) {
        float wx = 0.95047;
        float wy = 1.0;
        float wz = 1.08883;
        float fx = czLabF(xyz.x / wx);
        float fy = czLabF(xyz.y / wy);
        float fz = czLabF(xyz.z / wz);
        return vec3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz));
    }

    vec3 czLabToXYZ(vec3 lab) {
        float wx = 0.95047;
        float wy = 1.0;
        float wz = 1.08883;
        float fy = (lab.x + 16.0) / 116.0;
        float fx = fy + lab.y / 500.0;
        float fz = fy - lab.z / 200.0;
        return vec3(wx * czLabFInverse(fx), wy * czLabFInverse(fy), wz * czLabFInverse(fz));
    }

    kernel vec4 colorZones(
        sampler image,
        vec4 lNodeX0, vec4 lNodeX1, vec4 lNodeY0, vec4 lNodeY1, vec4 lNodeM0, vec4 lNodeM1, float lCount,
        vec4 cNodeX0, vec4 cNodeX1, vec4 cNodeY0, vec4 cNodeY1, vec4 cNodeM0, vec4 cNodeM1, float cCount,
        vec4 hNodeX0, vec4 hNodeX1, vec4 hNodeY0, vec4 hNodeY1, vec4 hNodeM0, vec4 hNodeM1, float hCount)
    {
        vec4 pix = sample(image, samplerCoord(image));
        vec3 rgb = max(pix.rgb, vec3(0.0));
        vec3 lab = czXyzToLab(czRgbToXYZ(rgb));

        float a = lab.y;
        float b = lab.z;
        float twoPi = 6.283185307179586;
        float hue = fract((atan(b, a) + twoPi) / twoPi);
        float C = length(vec2(a, b));

        float select = hue;
        float oneMinus = 1.0 - C / 128.0;
        float blend = oneMinus * oneMinus;

        float lLookup = curveEval(select, lNodeX0, lNodeX1, lNodeY0, lNodeY1, lNodeM0, lNodeM1, lCount);
        float hLookup = curveEval(select, hNodeX0, hNodeX1, hNodeY0, hNodeY1, hNodeM0, hNodeM1, hCount);
        float cLookup = curveEval(select, cNodeX0, cNodeX1, cNodeY0, cNodeY1, cNodeM0, cNodeM1, cCount);

        float Lm = (blend * 0.5 + (1.0 - blend) * lLookup) - 0.5;
        float hm = (blend * 0.5 + (1.0 - blend) * hLookup) - 0.5;
        float Cm = 2.0 * cLookup;

        float LOut = lab.x * pow(2.0, 4.0 * Lm);
        float hOut = hue + hm;
        float aOut = cos(twoPi * hOut) * Cm * C;
        float bOut = sin(twoPi * hOut) * Cm * C;

        vec3 outRgb = czXyzToRGB(czLabToXYZ(vec3(LOut, aOut, bOut)));
        return vec4(outRgb, pix.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        CIColorKernel(source: source)
    }()

    /// Renders `image` through the color zones EQ. Returns `image` unchanged if the kernel
    /// failed to compile, or if all 3 curves have fewer than 2 points (nothing to evaluate).
    static func apply(to image: CIImage, params: ColorZonesParameters) -> CIImage {
        guard let kernel,
              params.lightnessPoints.count >= 2,
              params.chromaPoints.count >= 2,
              params.huePoints.count >= 2
        else { return image }

        func packedArgs(_ points: [SIMD2<Double>]) -> [Any] {
            let spline = RGBCurveSpline(points: points.map { (x: $0.x, y: $0.y) }, type: .catmullRom)
            let n = min(spline.nodesX.count, maxNodes)

            var xs = spline.nodesX.prefix(n).map(Float.init)
            var ys = spline.nodesY.prefix(n).map(Float.init)
            var ms = spline.tangents.prefix(n).map(Float.init)
            while xs.count < maxNodes {
                xs.append(xs[n - 1])
                ys.append(ys[n - 1])
                ms.append(0)
            }

            func pack(_ values: [Float], _ lo: Int) -> CIVector {
                CIVector(x: CGFloat(values[lo]), y: CGFloat(values[lo + 1]), z: CGFloat(values[lo + 2]), w: CGFloat(values[lo + 3]))
            }

            return [
                pack(xs, 0), pack(xs, 4),
                pack(ys, 0), pack(ys, 4),
                pack(ms, 0), pack(ms, 4),
                Float(n)
            ]
        }

        let arguments: [Any] = [image]
            + packedArgs(params.lightnessPoints)
            + packedArgs(params.chromaPoints)
            + packedArgs(params.huePoints)

        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }
}
