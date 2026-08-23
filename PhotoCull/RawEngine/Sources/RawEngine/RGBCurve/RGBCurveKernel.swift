import CoreImage
import Foundation

/// Applies the RGB tone curve to a `CIImage` via a custom `CIColorKernel`, evaluating the same
/// monotone-Hermite spline as `RGBCurveSpline` (kept in sync deliberately — see
/// `RGBCurveKernelTests` for a numerical cross-check) either per-channel or as a
/// luminance-preserving ratio, matching darktable's `process()` in `rgbcurve.c`. See
/// `RGBCurveParameters` for the scope note on which of darktable's modes this corresponds to.
/// After the curve, `RGBCurveParameters.blackLift` (not part of darktable's module) applies a
/// uniform lift/gamma/gain-style lift to the result — see the kernel source's final line.
public enum RGBCurveKernel {
    /// Up to 8 control points (7 segments), packed as pairs of `vec4` so every argument is a
    /// plain scalar/vector Core Image can marshal — no dynamic array parameters, matching
    /// `FilmicRGBKernel`'s approach. Padding slots beyond the real point count duplicate the
    /// last real node, which is inert since the kernel only ever walks `nodeCount - 1` segments.
    /// Public so UI code (`CurveEditorControl`) can cap how many points a user can add.
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

    kernel vec4 rgbCurve(
        sampler image,
        vec4 nodeX0, vec4 nodeX1,
        vec4 nodeY0, vec4 nodeY1,
        vec4 nodeM0, vec4 nodeM1,
        float nodeCount,
        float preserveColors,
        float blackLift)
    {
        vec4 pix = sample(image, samplerCoord(image));
        vec3 c = pix.rgb;
        vec3 outc;

        if (preserveColors > 0.5) {
            float lum = dot(c, vec3(0.2225045, 0.7168786, 0.0606169));
            float ratio = 1.0;
            if (lum > 0.0) {
                float curveLum = curveEval(lum, nodeX0, nodeX1, nodeY0, nodeY1, nodeM0, nodeM1, nodeCount);
                ratio = curveLum / lum;
            }
            outc = c * ratio;
        } else {
            outc.x = curveEval(c.x, nodeX0, nodeX1, nodeY0, nodeY1, nodeM0, nodeM1, nodeCount);
            outc.y = curveEval(c.y, nodeX0, nodeX1, nodeY0, nodeY1, nodeM0, nodeM1, nodeCount);
            outc.z = curveEval(c.z, nodeX0, nodeX1, nodeY0, nodeY1, nodeM0, nodeM1, nodeCount);
        }

        // Lift/gamma/gain-style lift: raises the floor while leaving white (1.0) pinned in place.
        outc = outc * (1.0 - blackLift) + blackLift;

        return vec4(outc, pix.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        CIColorKernel(source: source)
    }()

    /// Renders `image` through the RGB curve. Returns `image` unchanged if the kernel failed to
    /// compile, or if `params` has fewer than 2 points (nothing to interpolate).
    static func apply(to image: CIImage, params: RGBCurveParameters) -> CIImage {
        guard let kernel, params.points.count >= 2 else { return image }

        let spline = RGBCurveSpline(points: params.points.map { (x: $0.x, y: $0.y) })
        let n = min(spline.nodesX.count, maxNodes)

        var xs = spline.nodesX.prefix(n).map(Float.init)
        var ys = spline.nodesY.prefix(n).map(Float.init)
        var ms = spline.tangents.prefix(n).map(Float.init)
        while xs.count < maxNodes {
            xs.append(xs[n - 1])
            ys.append(ys[n - 1])
            ms.append(0)
        }

        func pack(_ values: [Float], _ lo: Int, _ hi: Int) -> CIVector {
            CIVector(x: CGFloat(values[lo]), y: CGFloat(values[lo + 1]), z: CGFloat(values[lo + 2]), w: CGFloat(values[lo + 3]))
        }

        let arguments: [Any] = [
            image,
            pack(xs, 0, 3), pack(xs, 4, 7),
            pack(ys, 0, 3), pack(ys, 4, 7),
            pack(ms, 0, 3), pack(ms, 4, 7),
            Float(n),
            Float(params.preserveColors ? 1 : 0),
            Float(params.blackLift)
        ]

        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }
}
