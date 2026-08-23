import COpenImageDenoise
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Applies AI-based noise reduction via Intel Open Image Denoise's "RT" filter — a pretrained
/// U-Net-style CNN, run on the GPU through OIDN's Metal device backend (`oidn.h`; the vendored
/// dylibs and their Apache-2.0 license live in `RawEngine/Vendor`). Unlike every other module in
/// this package, this one can't stay a lazy Core Image kernel: OIDN needs real pixel data in a
/// host buffer, not a `CIImage` graph node, so `apply(to:params:draft:)` eagerly renders `image`
/// into a half-float buffer, hands it to OIDN, and wraps the result back into a `CIImage`
/// afterward — the one place in `RawEngine` that forces a render mid-pipeline rather than letting
/// Core Image fuse everything lazily at the final `CIContext.render` call in `RawImageRenderer`.
///
/// Performance note: unlike the CIKernel-based modules, this is a real neural-net inference pass,
/// not a cheap per-pixel formula. It's still safe to call on every editor slider tick — the app
/// target's `EditorRenderCoordinator` already coalesces a burst of `scheduleRender` calls down to
/// "run whatever's newest once the previous render is free" and does a cheap `draft` pass (this
/// filter's "balanced" OIDN quality mode) during the drag, a crisp one only once input settles —
/// but that coalescing is what makes it safe, not anything in this file. Don't call this directly
/// from a tight per-frame loop that bypasses that mechanism.
enum DenoiseFilter {
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// One process-lifetime OIDN device, reused across calls — device creation compiles/uploads
    /// the network's weights to the GPU, which is far too expensive to redo per render. `nil` if
    /// this Mac has no usable Metal device for OIDN (falls back to returning `image` unmodified).
    private static let device: OIDNDevice? = {
        guard let device = oidnNewDevice(OIDN_DEVICE_TYPE_METAL) else { return nil }
        oidnCommitDevice(device)
        return oidnGetDeviceError(device, nil) == OIDN_ERROR_NONE ? device : nil
    }()

    /// Returns `image` unchanged if `amount <= 0` (no-op), the image has no finite pixel extent,
    /// or OIDN itself is unavailable/fails — denoising is always a quality enhancement on top of
    /// an otherwise-complete render, never something the rest of the pipeline should depend on
    /// succeeding. `draft`, matching `RawImageRenderer.renderPreview`'s parameter of the same
    /// name, trades quality for speed by selecting OIDN's "balanced" quality mode instead of
    /// "high" — pass `true` while the user is actively dragging a control.
    static func apply(to image: CIImage, params: DenoiseParameters, draft: Bool = false) -> CIImage {
        guard params.amount > 0, let device else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())

        let bytesPerPixel = 8 // OIDN_FORMAT_HALF3 read out of an RGBA-half-float buffer (4 * 2 bytes), alpha slot untouched.
        let rowByteStride = width * bytesPerPixel
        let byteSize = rowByteStride * height

        guard let buffer = oidnNewBufferWithStorage(device, byteSize, OIDN_STORAGE_HOST),
              let bufferData = oidnGetBufferData(buffer) else { return image }
        defer { oidnReleaseBuffer(buffer) }

        let context = CIContext()
        context.render(
            image, toBitmap: bufferData, rowBytes: rowByteStride,
            bounds: extent, format: .RGBAh, colorSpace: workingColorSpace
        )

        guard let filter = oidnNewFilter(device, "RT") else { return image }
        defer { oidnReleaseFilter(filter) }
        oidnSetFilterImage(filter, "color", buffer, OIDN_FORMAT_HALF3, width, height, 0, bytesPerPixel, rowByteStride)
        oidnSetFilterImage(filter, "output", buffer, OIDN_FORMAT_HALF3, width, height, 0, bytesPerPixel, rowByteStride)
        oidnSetFilterBool(filter, "hdr", true)
        oidnSetFilterBool(filter, "srgb", false)
        oidnSetFilterInt(filter, "quality", Int32((draft ? OIDN_QUALITY_BALANCED : OIDN_QUALITY_HIGH).rawValue))
        oidnCommitFilter(filter)
        guard oidnGetDeviceError(device, nil) == OIDN_ERROR_NONE else { return image }
        oidnExecuteFilter(filter)
        guard oidnGetDeviceError(device, nil) == OIDN_ERROR_NONE else { return image }

        let denoisedData = Data(bytes: bufferData, count: byteSize)
        var denoised = CIImage(
            bitmapData: denoisedData, bytesPerRow: rowByteStride,
            size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: workingColorSpace
        )
        if extent.origin != .zero {
            denoised = denoised.transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
        }

        if params.amount >= 1 { return denoised }
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = denoised
        dissolve.time = Float(params.amount)
        return dissolve.outputImage?.cropped(to: extent) ?? denoised
    }
}
