import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies dark-channel-prior haze removal to a `CIImage`. Unlike every other kernel in this
/// module (`FilmicRGBKernel`, `ColorBalanceRGBKernel`, ...), this one isn't a pure per-pixel
/// `CIColorKernel` pass — the dark channel prior is fundamentally a *local* (windowed) statistic,
/// not a function of one pixel's own value, so it needs a genuine spatial filter first.
///
/// Two-step pipeline: `CIFilter.morphologyMinimum` (a hardware-accelerated per-channel local-
/// minimum/erosion filter Core Image ships natively) computes the windowed channel-wise minimum
/// in one pass — taking the min across RGB afterward, inside `dehaze`'s kernel body, gives exactly
/// the dark channel (spatial-min and channel-min commute, so per-channel-then-per-pixel is
/// equivalent to the textbook per-pixel-then-per-window definition). That result feeds a second,
/// ordinary two-sampler `CIColorKernel` that applies the haze-removal formula per pixel.
///
/// Scope note: atmospheric light `A` is fixed at a near-white 1.0 rather than estimated from the
/// image's own brightest pixels (the textbook approach samples the top 0.1% of dark-channel
/// pixels, then picks the brightest original pixel among those) — a reasonable simplification for
/// a single user-facing "Dehaze" slider rather than a fully automatic algorithm, and it keeps this
/// a single, edit-stable pass with no image-wide statistics to compute up front.
enum DehazeKernel {
    private static let source = """
    kernel vec4 dehaze(sampler image, sampler dark, float amount, float atmosphericLight, float transmissionFloor)
    {
        vec4 pix = sample(image, samplerCoord(image));
        vec4 darkPix = sample(dark, samplerCoord(dark));
        float darkChannel = min(darkPix.r, min(darkPix.g, darkPix.b));

        float transmission = clamp(1.0 - amount * darkChannel, transmissionFloor, 1.0);
        vec3 rgb = (pix.rgb - atmosphericLight) / transmission + atmosphericLight;
        rgb = clamp(rgb, 0.0, 1.0);

        return vec4(rgb, pix.a);
    }
    """

    private static let kernel: CIColorKernel? = {
        CIColorKernel(source: source)
    }()

    /// Assumed atmospheric light color — see the scope note above.
    private static let atmosphericLight: Float = 1.0
    /// Floor on the estimated transmission — without this, pixels the dark-channel estimate
    /// considers "fully hazy" would divide by a near-zero transmission and blow out to noise.
    private static let transmissionFloor: Float = 0.15

    static func apply(to image: CIImage, params: DehazeParameters) -> CIImage {
        guard let kernel, params.amount > 0 else { return image }

        let shortSide = min(image.extent.width, image.extent.height)
        guard shortSide > 0 else { return image }
        // Window radius scaled to the image's own size (not a fixed pixel count) so the dark
        // channel's spatial scale — and therefore the effect's look — stays consistent between a
        // downscaled preview render and a full-resolution export.
        let radius = Float(min(max(shortSide * 0.015, 3), 40))

        let morphology = CIFilter.morphologyMinimum()
        morphology.inputImage = image
        morphology.radius = radius
        guard let darkChannel = morphology.outputImage?.cropped(to: image.extent) else { return image }

        let arguments: [Any] = [
            image,
            darkChannel,
            Float(params.amount),
            atmosphericLight,
            transmissionFloor
        ]

        return kernel.apply(extent: image.extent, arguments: arguments) ?? image
    }
}
