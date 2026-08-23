import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Edge-aware refinement for a rough, hand-painted mask: given the source photo as guidance,
/// snaps the mask's boundary to nearby real edges (strong luminance transitions) and smooths it
/// within visually uniform regions. Classical guided filter (He, Sun, Tang — "Guided Image
/// Filtering", ECCV 2010), not a learned/ML model — a locally-linear regression between the
/// guidance image and the rough mask, computed entirely from stock Core Image filters (box blurs
/// plus elementwise arithmetic via the blend-mode filters), so there's no model to bundle and it
/// runs on the GPU the same way every other stage kernel in this app does.
enum GuidedMaskRefiner {
    enum RefineError: Error {
        case renderFailed
    }

    /// `radius` is the box-blur radius in pixels of `guideImage`'s own resolution — the rough
    /// scale of neighborhood the filter reasons about; larger snaps to edges farther from the
    /// original stroke but can bleed across nearby unrelated ones. `epsilon` is the regularization
    /// term: higher values treat more of the guidance image's texture as noise and smooth the
    /// result more; lower values snap more literally to any transition, however small. Ignores
    /// the caller's `CIContext` and renders with its own 32-bit-float one — see the working-format
    /// note below for why.
    static func refine(
        mask: CGImage, guideImage: CGImage, radius: Double = 12, epsilon: Double = 2e-3
    ) throws -> CGImage {
        // Core Image's default working format is half-float (16-bit); rendering at full 32-bit
        // float instead keeps `varI` (`E[I²] - E[I]²`, a subtraction of two nearly-equal numbers
        // in visually flat regions) precise enough that rounding can't push it negative.
        // `.workingColorSpace`/`.outputColorSpace: NSNull()` disable Core Image's color management
        // entirely — every operation below is plain linear-algebra arithmetic on raw component
        // values (the guided filter paper's math has no notion of color spaces), and leaving color
        // management on silently distorts every one of these values through gamma-style transforms.
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()
        ])
        let p = CIImage(cgImage: mask)
        let guideRGB = CIImage(cgImage: guideImage)

        // Luminance-only guidance — the mask has no color of its own, so only the photo's
        // brightness edges are meaningful to snap to.
        let mono = CIFilter.colorMonochrome()
        mono.inputImage = guideRGB
        mono.color = CIColor(red: 1, green: 1, blue: 1)
        mono.intensity = 1
        guard let I = mono.outputImage?.cropped(to: guideRGB.extent) else { throw RefineError.renderFailed }
        let extent = I.extent

        func boxBlur(_ image: CIImage) -> CIImage {
            let blur = CIFilter.boxBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(radius)
            return (blur.outputImage ?? image).cropped(to: extent)
        }
        func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.multiplyBlendMode()
            f.inputImage = a
            f.backgroundImage = b
            return (f.outputImage ?? a).cropped(to: extent)
        }
        // `CISubtractBlendMode` computes `backgroundImage - inputImage`, not
        // `inputImage - backgroundImage` as the parameter names suggest — confirmed empirically
        // (Apple's own prose docs say the opposite). Operands are swapped below so `subtract(a, b)`
        // actually returns `a - b`.
        func subtract(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.subtractBlendMode()
            f.inputImage = b
            f.backgroundImage = a
            return (f.outputImage ?? a).cropped(to: extent)
        }
        func add(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.additionCompositing()
            f.inputImage = a
            f.backgroundImage = b
            return (f.outputImage ?? a).cropped(to: extent)
        }
        func addConstant(_ a: CIImage, _ value: Double) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = a
            f.biasVector = CIVector(x: value, y: value, z: value, w: 0)
            return (f.outputImage ?? a).cropped(to: extent)
        }
        func scale(_ a: CIImage, by factor: Double) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = a
            f.rVector = CIVector(x: factor, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: factor, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: factor, w: 0)
            return (f.outputImage ?? a).cropped(to: extent)
        }
        // Same reversed convention as `CISubtractBlendMode` — `CIDivideBlendMode` computes
        // `backgroundImage / inputImage`. Swapped so `divide(a, b)` returns `a / b`.
        func divide(_ a: CIImage, _ b: CIImage) -> CIImage {
            let f = CIFilter.divideBlendMode()
            f.inputImage = b
            f.backgroundImage = a
            return (f.outputImage ?? a).cropped(to: extent)
        }
        func clamp(_ a: CIImage, min: Double, max: Double) -> CIImage {
            let f = CIFilter.colorClamp()
            f.inputImage = a
            f.minComponents = CIVector(x: min, y: min, z: min, w: 0)
            f.maxComponents = CIVector(x: max, y: max, z: max, w: 1)
            return (f.outputImage ?? a).cropped(to: extent)
        }

        // Guided filter: fit a local linear model q = a*I + b (per pixel, over a `radius`
        // neighborhood) that best predicts the rough mask `p` from the guidance image `I`, via
        // the closed-form least-squares solution — see the paper for the derivation.
        let meanI = boxBlur(I)
        let meanP = boxBlur(p)
        let corrI = boxBlur(multiply(I, I))
        let corrIp = boxBlur(multiply(I, p))
        // A [0,1]-range variable's variance can never exceed 0.25 or be negative — flooring at
        // zero here (see the doc comment above) is the second guard against the rounding-error
        // blowup, independent of the 32-bit working format.
        let varI = clamp(subtract(corrI, multiply(meanI, meanI)), min: 0, max: 0.25)
        // `covIp` (a covariance of two [0,1]-range variables) is mathematically bounded by ±0.25,
        // but `varI` is floored at exactly 0 in any flat region (sky, an out-of-focus background),
        // leaving `epsilon` alone as the denominator there — so floating-point noise in `covIp`
        // that's nowhere near real signal still divides down to a swing many times larger than any
        // legitimate coefficient, visible as a spurious bright blob wherever that noise happens to
        // peak (confirmed: an unpainted patch of sky lit up after the peak-normalization below was
        // added, because normalizing by the whole image's peak amplifies exactly this outlier).
        // Clamping to the range a well-formed coefficient can actually take suppresses it without
        // touching real signal anywhere near the painted region.
        let covIp = subtract(corrIp, multiply(meanI, meanP))
        let rawA = clamp(divide(covIp, addConstant(varI, epsilon)), min: -1, max: 1)
        // The clamp above bounds the *magnitude* of the noise but doesn't remove it — a flat
        // region still gets some nonzero `a`, just capped, and peak-normalization can still make
        // that visible. Explicitly zeroing `a` wherever there's no real local structure to anchor
        // it (varI near its floor) is the actual fix: a flat region has no edge to snap to, so its
        // coefficient should be exactly 0 (pure "trust the smoothed rough mask," `b` alone), not a
        // capped-but-still-nonzero guess. `structureWeight` ramps 0→1 over a small band above the
        // floor rather than a hard cutoff, so it doesn't introduce its own discontinuity at
        // genuinely soft, low-but-real-contrast edges.
        let structureWeight = clamp(scale(varI, by: 1 / 0.002), min: 0, max: 1)
        let a = multiply(rawA, structureWeight)
        let b = subtract(meanP, multiply(a, meanI))
        let meanA = boxBlur(a)
        let meanB = boxBlur(b)
        let rawQ = clamp(add(multiply(meanA, I), meanB), min: 0, max: 1)

        // The two box-blur passes (once for `meanA`/`meanB`, again implicitly through `a`/`b`
        // themselves depending on `meanI`/`meanP`) systematically pull `rawQ` well below the
        // confidence `p` was originally painted at — even a stroke's dead center, far from any
        // edge, comes out as a muted gray rather than the white it went in as. Rescaling by the
        // result's own peak restores full-strength coverage at the region the user actually meant
        // most confidently, while the sub-peak falloff around it — the whole reason to refine in
        // the first place — is preserved exactly as computed.
        let maxFilter = CIFilter.areaMaximum()
        maxFilter.inputImage = rawQ
        maxFilter.extent = extent
        var peakPixel = [Float](repeating: 0, count: 4)
        context.render(
            maxFilter.outputImage!, toBitmap: &peakPixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil
        )
        // Floors the gain at 1x (never *dims* a mask that's already strong) and avoids dividing by
        // a near-zero peak — a stroke refined down to nothing shouldn't get amplified into noise.
        let gain = peakPixel[0] > 0.05 ? Double(1 / peakPixel[0]) : 1
        let q = clamp(scale(rawQ, by: gain), min: 0, max: 1)

        guard let output = context.createCGImage(q, from: extent) else {
            throw RefineError.renderFailed
        }
        return output
    }
}
