import CoreImage
import Foundation

/// Corrects one render's lens-specific geometric distortion, vignetting, and transverse chromatic
/// aberration in a single GPU pass — a faithful (if not byte-for-byte identical, see
/// `LensCorrectionDatabase`'s doc comment on interpolation) port of lensfun's own correction math
/// (`mod-coord.cpp`/`mod-color.cpp`/`mod-subpix.cpp`), since vendoring lensfun's actual C library
/// isn't a practical fit for this package (see `LensCorrectionDatabase`'s doc comment).
///
/// Unlike every other kernel in `RawEngine`, this one moves a pixel's *position*, not just its
/// color — a general `CIKernel` (not `CIColorKernel`), since it samples `image` at up to three
/// different positions (one per color channel — transverse chromatic aberration shifts red and blue
/// independently of green) and combines them into one output pixel. Each position is computed as an
/// absolute destination-space coordinate and converted into `image`'s own coordinate space via
/// `samplerTransform`, not as a raw pixel-unit offset added to `samplerCoord(image)` — the offset
/// form looks equivalent for a plain, unrotated image, but silently samples in the wrong direction
/// whenever `image` carries a pending orientation-rotation transform (routine for portrait-oriented
/// photos), which reads as the whole corrected image tilting slightly. `samplerTransform` is the
/// primitive that actually accounts for whatever transform sits between the two spaces.
///
/// All three corrections this supports (`poly3`/`poly5`/`ptlens` distortion, `pa` vignetting,
/// `linear`/`poly3` TCA — the only models present in the bundled database) are purely radial
/// (functions of `x²+y²` only, never of `x`/`y`'s individual sign), so unlike a directional
/// transform, getting Core Image's y-axis convention backwards here would have zero visible effect
/// on correctness — which is why nothing in this kernel branches on it.
///
/// Coordinate system matches lensfun's own (`modifier.cpp`'s doc comment): pixel coordinates are
/// converted to "normalized" units — the image's own half-diagonal in real-focal-length units, lens-
/// centered — via `NormScale`/`CenterX`/`CenterY`, computed fresh per render from that render's own
/// pixel dimensions (a preview render and a full-resolution export need different values here, same
/// reason `DehazeKernel` scales its morphology radius by the image's own size rather than a fixed
/// pixel count).
enum LensCorrectionKernel {
    private static let source = """
    kernel vec4 lensCorrect(
        sampler image,
        float normScale, float centerX, float centerY, float originX, float originY,
        float distKind, float distA, float distB, float distC, float autoScale,
        float tcaKind, float tcaVr, float tcaVb, float tcaCr, float tcaCb, float tcaBr, float tcaBb,
        float hasVignetting, float vigK1, float vigK2, float vigK3,
        float intensity)
    {
        vec2 dc = destCoord() - vec2(originX, originY);
        // `autoScale` (<= 1, computed once on the CPU side in `apply(to:params:)`) zooms in slightly
        // around the lens center before distortion runs, exactly cancelling out however far the
        // uncorrected frame's edges would otherwise need to sample beyond the original image —
        // without it, barrel-distortion correction reads blank/extrapolated pixels into the output
        // near the edges and corners, which reads at a glance as if the whole photo had rotated.
        float x = (dc.x * normScale - centerX) * autoScale;
        float y = (dc.y * normScale - centerY) * autoScale;
        float ru2 = x * x + y * y;

        // Forward distortion: undistorted (x,y) -> distorted (xg,yg), i.e. where in the original,
        // as-shot image this corrected-output pixel should sample from. See mod-coord.cpp's
        // ModifyCoord_Dist_Poly3/Poly5/PTLens — `distA`/`distB`/`distC` already carry the rescaled
        // (not raw XML) coefficients, computed once on the CPU side in `apply(to:params:)`.
        float poly = 1.0;
        if (distKind > 0.5 && distKind < 1.5) {
            poly = distA * ru2 + 1.0;
        } else if (distKind > 1.5 && distKind < 2.5) {
            poly = 1.0 + distA * ru2 + distB * ru2 * ru2;
        } else if (distKind > 2.5) {
            float r = sqrt(ru2);
            poly = distA * ru2 * r + distB * ru2 + distC * r + 1.0;
        }
        float xg = x * poly;
        float yg = y * poly;

        // TCA: a further per-channel radial rescale on top of the already-distorted (xg,yg) —
        // green is left untouched as the reference channel. See mod-subpix.cpp's
        // ModifyCoord_TCA_Linear/ModifyCoord_TCA_Poly3.
        float xr = xg;
        float yr = yg;
        float xb = xg;
        float yb = yg;
        if (tcaKind > 0.5 && tcaKind < 1.5) {
            xr = xg * tcaVr; yr = yg * tcaVr;
            xb = xg * tcaVb; yb = yg * tcaVb;
        } else if (tcaKind > 1.5) {
            float rug2 = xg * xg + yg * yg;
            float rug = sqrt(rug2);
            float polyR = tcaBr * rug2 + tcaCr * rug + tcaVr;
            float polyB = tcaBb * rug2 + tcaCb * rug + tcaVb;
            xr = xg * polyR; yr = yg * polyR;
            xb = xg * polyB; yb = yg * polyB;
        }

        // Absolute destination-space pixel coordinates to sample at, not offsets from the current
        // pixel — `samplerTransform` (not `samplerCoord(image) + delta`) is what correctly maps
        // these into `image`'s own coordinate space. That distinction matters here specifically: a
        // portrait-oriented photo's `CIImage` commonly carries a pending orientation-rotation
        // transform that isn't resolved to actual pixel data until render time, and a raw pixel
        // delta computed in destination space doesn't get rotated along with it — sampling via
        // `samplerCoord(image) + delta` in that case reads from the *wrong*, unrotated direction,
        // which looks exactly like the whole corrected image tilting slightly with fresh pixels
        // dragged in at the edges. `samplerTransform` accounts for whatever transform sits between
        // the two coordinate spaces, rotation included.
        vec2 pxG = vec2((xg + centerX) / normScale, (yg + centerY) / normScale) + vec2(originX, originY);
        vec2 pxR = vec2((xr + centerX) / normScale, (yr + centerY) / normScale) + vec2(originX, originY);
        vec2 pxB = vec2((xb + centerX) / normScale, (yb + centerY) / normScale) + vec2(originX, originY);

        vec4 pixG = sample(image, samplerTransform(image, pxG));
        vec4 pixR = sample(image, samplerTransform(image, pxR));
        vec4 pixB = sample(image, samplerTransform(image, pxB));

        vec3 corrected = vec3(pixR.r, pixG.g, pixB.b);

        // Vignetting: a per-source-pixel brightness correction at the same distorted (pre-TCA)
        // position the green channel sampled from — that's the position this light actually landed
        // at in the original, as-shot image, which is what the falloff is a function of. See
        // mod-color.cpp's ModifyColor_DeVignetting_PA.
        if (hasVignetting > 0.5) {
            float r2 = xg * xg + yg * yg;
            float r4 = r2 * r2;
            float r6 = r4 * r2;
            float gain = 1.0 + vigK1 * r2 + vigK2 * r4 + vigK3 * r6;
            corrected = corrected / max(gain, 0.05);
        }

        vec4 original = sample(image, samplerTransform(image, destCoord()));
        vec3 outRGB = mix(original.rgb, corrected, intensity);
        return vec4(outRGB, pixG.a);
    }
    """

    private static let kernel: CIKernel? = {
        CIKernel(source: source)
    }()

    static func apply(to image: CIImage, params: LensCorrectionParameters) -> CIImage {
        guard let kernel, !params.isEmpty, params.intensity > 0 else { return image }

        let extent = image.extent
        let w = extent.width >= 2 ? extent.width - 1 : 1
        let h = extent.height >= 2 ? extent.height - 1 : 1
        guard w > 0, h > 0, params.cameraCropFactor > 0, params.realFocalLength > 0 else { return image }

        // See modifier.cpp's lfModifier constructor: NormScale converts pixel distances into units
        // of the real focal length, using the diagonal of a 43.27mm (35mm-equivalent) sensor scaled
        // by this render's own camera crop factor and pixel dimensions (+1 for the outer pixel rim).
        let normScale = hypot(36.0, 24.0) / params.cameraCropFactor / hypot(w + 1, h + 1) / params.realFocalLength
        let centerX = (w / 2.0) * normScale
        let centerY = (h / 2.0) * normScale

        var distKind: Float = 0
        var distA: Double = 0, distB: Double = 0, distC: Double = 0
        var autoScale: Double = 1
        if let distortion = params.distortion {
            let r = rescaledDistortion(
                distortion, realFocal: params.realFocalLength,
                cropFactor: params.calibrationCropFactor, aspectRatio: params.calibrationAspectRatio
            )
            distKind = r.kind
            distA = r.a; distB = r.b; distC = r.c
            autoScale = autoScaleFactor(kind: distKind, a: distA, b: distB, c: distC, centerX: centerX, centerY: centerY)
        }

        var tcaKind: Float = 0
        var tcaVr = 1.0, tcaVb = 1.0, tcaCr = 0.0, tcaCb = 0.0, tcaBr = 0.0, tcaBb = 0.0
        if let tca = params.tca {
            let r = rescaledTCA(
                tca, realFocal: params.realFocalLength,
                cropFactor: params.calibrationCropFactor, aspectRatio: params.calibrationAspectRatio
            )
            tcaKind = r.kind
            tcaVr = r.vr; tcaVb = r.vb; tcaCr = r.cr; tcaCb = r.cb; tcaBr = r.br; tcaBb = r.bb
        }

        var hasVignetting: Float = 0
        var vigK1 = 0.0, vigK2 = 0.0, vigK3 = 0.0
        if let vignetting = params.vignetting {
            let r = rescaledVignetting(vignetting, realFocal: params.realFocalLength, cropFactor: params.calibrationCropFactor)
            hasVignetting = 1
            vigK1 = r.k1; vigK2 = r.k2; vigK3 = r.k3
        }

        let arguments: [Any] = [
            image,
            Float(normScale), Float(centerX), Float(centerY), Float(extent.origin.x), Float(extent.origin.y),
            distKind, Float(distA), Float(distB), Float(distC), Float(autoScale),
            tcaKind, Float(tcaVr), Float(tcaVb), Float(tcaCr), Float(tcaCb), Float(tcaBr), Float(tcaBb),
            hasVignetting, Float(vigK1), Float(vigK2), Float(vigK3),
            Float(params.intensity)
        ]

        // Distortion correction shrinks or grows the image slightly (see the "Note about PT-based
        // distortion models" comment at the top of lensfun's own `mod-coord.cpp`), so a corrected
        // pixel can legitimately need to sample from anywhere in the original extent — the full
        // extent is the correct (if conservative) region-of-interest for every output region.
        return kernel.apply(extent: extent, roiCallback: { _, _ in extent }, arguments: arguments) ?? image
    }

    /// A simplified stand-in for lensfun's own `GetAutoScale` (`mod-coord.cpp`): the smallest
    /// zoom-in factor (`<= 1`) that keeps every one of 8 boundary points (4 corners + 4 edge
    /// midpoints, matching `GetAutoScale`'s own sampling pattern) sampling from *inside* the
    /// original captured frame after distortion. Barrel-distortion correction (the common case at a
    /// lens' wide end) needs to read from outside the original frame near the edges to fill the
    /// output — without correcting for that, those pixels come back blank/transparent, which reads
    /// on a photo with strong straight lines as if the whole image had tilted rather than what it
    /// actually is: an uneven, uncorrected border.
    ///
    /// Finds the crossing point by bisection rather than porting `GetAutoScale`'s own Newton's-method
    /// search — the polynomial models this supports are smooth and (well within the focal ranges
    /// real calibrations cover) monotonic in the boundary region, so a plain bisection converges to
    /// the same answer without the extra complexity.
    private static func autoScaleFactor(kind: Float, a: Double, b: Double, c: Double, centerX: Double, centerY: Double) -> Double {
        guard kind > 0.5, centerX > 0, centerY > 0 else { return 1 }

        func poly(_ ru2: Double) -> Double {
            if kind < 1.5 { return a * ru2 + 1 }
            if kind < 2.5 { return 1 + a * ru2 + b * ru2 * ru2 }
            let r = ru2.squareRoot()
            return a * ru2 * r + b * ru2 + c * r + 1
        }

        let boundaryPoints: [(Double, Double)] = [
            (centerX, centerY), (-centerX, centerY), (-centerX, -centerY), (centerX, -centerY),
            (centerX, 0), (-centerX, 0), (0, centerY), (0, -centerY)
        ]

        // Largest ratio (over every boundary point) of how far outside the original frame that
        // point's distorted position would land, at zoom level `s`. <= 1 means every point stays
        // safely inside — no blank border.
        func worstRatio(_ s: Double) -> Double {
            var worst = 0.0
            for (x0, y0) in boundaryPoints {
                let x = x0 * s, y = y0 * s
                let p = poly(x * x + y * y)
                worst = max(worst, abs(x * p) / centerX, abs(y * p) / centerY)
            }
            return worst
        }

        guard worstRatio(1) > 1 else { return 1 }

        var lo = 0.0, hi = 1.0
        for _ in 0..<25 {
            let mid = (lo + hi) / 2
            if worstRatio(mid) > 1 { hi = mid } else { lo = mid }
        }
        return lo
    }

    // MARK: - lensfun's rescale_polynomial_coefficients, ported

    /// See `mod-coord.cpp`'s `rescale_polynomial_coefficients` — converts the raw XML coefficients
    /// (calibrated in Hugin's own coordinate system, where `r = 1` at half the image's long edge)
    /// into this render's natural, focal-length-based normalized coordinate system, so
    /// `LensCorrectionKernel`'s GLSL body can evaluate the simple polynomial directly with no
    /// per-pixel rescaling. `kind` mirrors the kernel's own `distKind` selector (1 = poly3, 2 =
    /// poly5, 3 = ptlens).
    private static func rescaledDistortion(
        _ model: LensDistortionModel, realFocal: Double, cropFactor: Double, aspectRatio: Double
    ) -> (kind: Float, a: Double, b: Double, c: Double) {
        let huginScaleMM = hypot(36.0, 24.0) / cropFactor / hypot(aspectRatio, 1) / 2.0
        guard huginScaleMM > 0 else { return (0, 0, 0, 0) }
        let huginScaling = realFocal / huginScaleMM
        switch model {
        case .poly3(let k1):
            let d = 1 - k1
            guard d != 0 else { return (1, 0, 0, 0) }
            return (1, k1 * pow(huginScaling, 2) / pow(d, 3), 0, 0)
        case .poly5(let k1, let k2):
            return (2, k1 * pow(huginScaling, 2), k2 * pow(huginScaling, 4), 0)
        case .ptlens(let a, let b, let c):
            let d = 1 - a - b - c
            guard d != 0 else { return (3, 0, 0, 0) }
            return (3, a * pow(huginScaling, 3) / pow(d, 4), b * pow(huginScaling, 2) / pow(d, 3), c * huginScaling / pow(d, 2))
        }
    }

    /// See `mod-color.cpp`'s `rescale_polynomial_coefficients` — same idea as the distortion
    /// version above, but the "pa" vignetting model's Hugin coordinate system normalizes `r = 1` at
    /// the image *corner* (no aspect-ratio term), not the half-height.
    private static func rescaledVignetting(_ terms: LensVignettingTerms, realFocal: Double, cropFactor: Double) -> (k1: Double, k2: Double, k3: Double) {
        let huginScaleMM = hypot(36.0, 24.0) / cropFactor / 2.0
        guard huginScaleMM > 0 else { return (0, 0, 0) }
        let huginScaling = realFocal / huginScaleMM
        return (terms.k1 * pow(huginScaling, 2), terms.k2 * pow(huginScaling, 4), terms.k3 * pow(huginScaling, 6))
    }

    /// See `mod-subpix.cpp`'s `rescale_polynomial_coefficients`. The linear TCA model needs no
    /// rescaling in the (non-reverse) correction direction this app always uses — `kr`/`kb` are
    /// plain radial multipliers already in the right units.
    private static func rescaledTCA(
        _ model: LensTCAModel, realFocal: Double, cropFactor: Double, aspectRatio: Double
    ) -> (kind: Float, vr: Double, vb: Double, cr: Double, cb: Double, br: Double, bb: Double) {
        switch model {
        case .linear(let kr, let kb):
            return (1, kr, kb, 0, 0, 0, 0)
        case .poly3(let vr, let vb, let cr, let cb, let br, let bb):
            let huginScaleMM = hypot(36.0, 24.0) / cropFactor / hypot(aspectRatio, 1) / 2.0
            guard huginScaleMM > 0 else { return (2, vr, vb, 0, 0, 0, 0) }
            let huginScaling = realFocal / huginScaleMM
            return (2, vr, vb, cr * huginScaling, cb * huginScaling, br * huginScaling * huginScaling, bb * huginScaling * huginScaling)
        }
    }
}
