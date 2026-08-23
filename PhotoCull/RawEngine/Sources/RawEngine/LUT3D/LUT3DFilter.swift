import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies a parsed 3D LUT via Core Image's native `CIColorCubeWithColorSpace`, rather than a
/// custom `CIColorKernel` like the other four modules — Core Image already has a GPU-native path
/// for exactly this operation (including the trilinear interpolation), so there's no reason to
/// hand-roll it in CIKL. The `sRGB` color space tells Core Image the cube's samples are defined
/// against gamma-encoded sRGB, matching how virtually every distributed `.cube` film-simulation
/// LUT is authored (against a display-referred JPEG/sRGB preview, not scene-linear data) —
/// `RawImageRenderer.applyStage` runs this last, after every other grading pass, so the image is
/// already close to that display-referred state by the time it gets here.
enum LUT3DFilter {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Returns `image` unchanged if the cube is degenerate (`size < 2`) or the filter fails to
    /// produce output.
    static func apply(to image: CIImage, params: LUT3DParameters) -> CIImage {
        guard params.lut.size >= 2 else { return image }

        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(params.lut.size)
        cube.cubeData = params.lut.data
        cube.colorSpace = sRGB
        guard let graded = cube.outputImage?.cropped(to: image.extent) else { return image }

        if params.intensity >= 1 { return graded }
        if params.intensity <= 0 { return image }

        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = graded
        dissolve.time = Float(params.intensity)
        return dissolve.outputImage?.cropped(to: image.extent) ?? graded
    }
}
