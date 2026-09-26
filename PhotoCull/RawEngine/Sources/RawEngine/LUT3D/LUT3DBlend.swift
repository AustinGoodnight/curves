import CoreGraphics
import CoreImage
import Foundation

extension LUT3D {
    /// A single LUT equivalent to crossfading `a`'s output toward `b`'s by `t` (0 = all `a`, 1 = all
    /// `b`). Exact, not an approximation: `CIColorCube`'s trilinear lookup is linear in the table's
    /// node values, so blending the *tables* node-by-node gives the same pixels as rendering both
    /// LUTs and blending the images — at the render cost of one LUT. When the sizes differ, `b` is
    /// resampled (trilinearly) onto `a`'s grid first, which is the same interpolation the renderer
    /// would have applied to `b` anyway.
    public static func blend(_ a: LUT3D, _ b: LUT3D, t: Double, title: String? = nil) -> LUT3D {
        let mix = Float(min(max(t, 0), 1))
        let size = a.size
        let count = size * size * size * 4
        let aValues = a.floats
        let bValues = b.size == size ? b.floats : b.resampled(to: size)
        guard aValues.count == count, bValues.count == count else { return a }
        var out = [Float](repeating: 1, count: count)
        for i in 0..<count {
            out[i] = aValues[i] + (bValues[i] - aValues[i]) * mix
        }
        return LUT3D(size: size, data: out.withUnsafeBufferPointer { Data(buffer: $0) }, title: title)
    }

    fileprivate var floats: [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// This cube's table re-sampled onto a `size`-point grid via trilinear interpolation.
    fileprivate func resampled(to newSize: Int) -> [Float] {
        let source = floats
        let n = self.size
        guard source.count == n * n * n * 4, n >= 2 else { return [] }
        func node(_ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Float {
            source[((b * n + g) * n + r) * 4 + c]
        }
        var out = [Float]()
        out.reserveCapacity(newSize * newSize * newSize * 4)
        let step = Float(n - 1) / Float(newSize - 1)
        for bIndex in 0..<newSize {
            for gIndex in 0..<newSize {
                for rIndex in 0..<newSize {
                    let fr = Float(rIndex) * step, fg = Float(gIndex) * step, fb = Float(bIndex) * step
                    let r0 = min(Int(fr), n - 2), g0 = min(Int(fg), n - 2), b0 = min(Int(fb), n - 2)
                    let dr = fr - Float(r0), dg = fg - Float(g0), db = fb - Float(b0)
                    for c in 0..<3 {
                        let c00 = node(r0, g0, b0, c) * (1 - dr) + node(r0 + 1, g0, b0, c) * dr
                        let c10 = node(r0, g0 + 1, b0, c) * (1 - dr) + node(r0 + 1, g0 + 1, b0, c) * dr
                        let c01 = node(r0, g0, b0 + 1, c) * (1 - dr) + node(r0 + 1, g0, b0 + 1, c) * dr
                        let c11 = node(r0, g0 + 1, b0 + 1, c) * (1 - dr) + node(r0 + 1, g0 + 1, b0 + 1, c) * dr
                        let c0 = c00 * (1 - dg) + c10 * dg
                        let c1 = c01 * (1 - dg) + c11 * dg
                        out.append(c0 * (1 - db) + c1 * db)
                    }
                    out.append(1)
                }
            }
        }
        return out
    }
}

/// Applies a LUT to an already-rendered `CGImage` — for small previews/thumbnails of "this photo
/// through that LUT", without going back through the RAW pipeline. Same filter path as the real
/// render (`LUT3DFilter`), so a thumbnail matches what applying the LUT would produce.
public enum LUT3DPreview {
    private static let context = CIContext()

    public static func apply(_ lut: LUT3D, intensity: Double = 1, to image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = LUT3DFilter.apply(to: input, params: LUT3DParameters(lut: lut, intensity: intensity))
        return context.createCGImage(output, from: input.extent)
    }
}
