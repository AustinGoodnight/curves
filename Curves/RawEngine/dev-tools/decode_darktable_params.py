#!/usr/bin/env python3
"""Decodes a darktable IOP `darktable:params` XMP attribute (gzip-compressed, base64-encoded
C struct) into human-readable field values.

Usage:
    decode_darktable_params.py filmicrgb path/to/file.xmp

darktable's format is "gz" + 2 digits + base64(zlib-compressed raw struct bytes). The 2 digits
are not needed for decoding (verified empirically: skipping exactly 4 characters before
base64-decoding works regardless of their value). This was reverse-engineered from a real XMP
fixture, not from darktable's source (its XMP writer is in C++ engine internals not pulled into
this session) — verified correct by successfully decoding real field data into physically
sane values that also happened to match this app's own darktable-derived defaults exactly
(see RawEngine's FilmicRGBParameters).

Field specs below are transcribed directly from the real `dt_iop_..._params_t` struct
definitions in darktable's source (`src/iop/*.c`, tag release-5.6.0) — see the comment above
each spec for the exact source line range. Only `filmicrgb` (module version 6, matching
`DT_MODULE_INTROSPECTION(6, dt_iop_filmicrgb_params_t)`) is filled in; add more modules here
as later phases need to cross-check them (e.g. Phase 4's colorbalancergb).
"""
import base64
import re
import struct
import sys
import zlib

# dt_iop_filmicrgb_params_t, filmicrgb.c lines 167-198, release-5.6.0.
# 18 floats followed by 11 32-bit ints (enums / gboolean / int are all 4 bytes), tightly packed.
FILMICRGB_FLOAT_FIELDS = [
    "grey_point_source", "black_point_source", "white_point_source",
    "reconstruct_threshold", "reconstruct_feather", "reconstruct_bloom_vs_details",
    "reconstruct_grey_vs_color", "reconstruct_structure_vs_texture", "security_factor",
    "grey_point_target", "black_point_target", "white_point_target",
    "output_power", "latitude", "contrast", "saturation", "balance", "noise_level",
]
FILMICRGB_INT_FIELDS = [
    "preserve_color", "version", "auto_hardness", "custom_grey",
    "high_quality_reconstruction", "noise_distribution", "shadows", "highlights",
    "compensate_icc_black", "spline_version", "enable_highlight_reconstruction",
]

# dt_iop_colorbalancergb_params_t, colorbalancergb.c lines 60-106, release-5.6.0.
# 32 floats followed by 1 32-bit int (the saturation_formula enum), tightly packed.
COLORBALANCERGB_FLOAT_FIELDS = [
    "shadows_Y", "shadows_C", "shadows_H", "midtones_Y", "midtones_C", "midtones_H",
    "highlights_Y", "highlights_C", "highlights_H", "global_Y", "global_C", "global_H",
    "shadows_weight", "white_fulcrum", "highlights_weight", "chroma_shadows",
    "chroma_highlights", "chroma_global", "chroma_midtones", "saturation_global",
    "saturation_highlights", "saturation_midtones", "saturation_shadows", "hue_angle",
    "brilliance_global", "brilliance_highlights", "brilliance_midtones", "brilliance_shadows",
    "mask_grey_fulcrum", "vibrance", "grey_fulcrum", "contrast",
]
COLORBALANCERGB_INT_FIELDS = ["saturation_formula"]

MODULE_SPECS = {
    "filmicrgb": (FILMICRGB_FLOAT_FIELDS, FILMICRGB_INT_FIELDS),
    "colorbalancergb": (COLORBALANCERGB_FLOAT_FIELDS, COLORBALANCERGB_INT_FIELDS),
}


def decode_blob(blob: str) -> bytes:
    b64part = blob[4:]  # skip "gz" + 2 digits
    raw = base64.b64decode(b64part + "=" * (-len(b64part) % 4))
    return zlib.decompress(raw)


def find_params(xmp_text: str, operation: str) -> list[str]:
    pattern = re.compile(
        r'darktable:operation="%s".*?darktable:params="([^"]+)"' % re.escape(operation),
        re.DOTALL,
    )
    return pattern.findall(xmp_text)


def main() -> None:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <operation> <xmp-file>", file=sys.stderr)
        sys.exit(1)

    operation, xmp_path = sys.argv[1], sys.argv[2]
    if operation not in MODULE_SPECS:
        print(f"no field spec for '{operation}'; add one to MODULE_SPECS", file=sys.stderr)
        sys.exit(1)

    float_fields, int_fields = MODULE_SPECS[operation]
    expected_len = 4 * (len(float_fields) + len(int_fields))

    xmp_text = open(xmp_path, encoding="utf-8").read()
    blobs = find_params(xmp_text, operation)
    if not blobs:
        print(f"no '{operation}' module found in {xmp_path}", file=sys.stderr)
        sys.exit(1)

    for i, blob in enumerate(blobs):
        raw = decode_blob(blob)
        print(f"--- {operation} instance {i} ({len(raw)} bytes, expected {expected_len}) ---")
        if len(raw) != expected_len:
            print("  (size mismatch — struct spec above may be stale for this modversion)")
            continue
        floats = struct.unpack(f"<{len(float_fields)}f", raw[: 4 * len(float_fields)])
        ints = struct.unpack(f"<{len(int_fields)}i", raw[4 * len(float_fields) :])
        for name, value in zip(float_fields, floats):
            print(f"  {name} = {value}")
        for name, value in zip(int_fields, ints):
            print(f"  {name} = {value}")


if __name__ == "__main__":
    main()
