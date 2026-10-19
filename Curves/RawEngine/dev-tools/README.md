# Filmic RGB / Color Balance RGB verification harness (Phases 3–4)

Dev-time tools for checking `FilmicSpline`/`FilmicRGBKernel` and `ColorBalanceRGBProcessor`/
`ColorBalanceRGBKernel` against real darktable behavior. Not part of the app or the automated
test target — these need a local darktable install and the test RAW fixture from
`PROJECT_BRIEF.md`, neither of which is portable to CI.

## What this does and does not prove

A literal pixel-diff between our full pipeline's export and darktable-cli's full export is
**not achievable and not meaningful** for this phase: `CIRAWFilter` (our validated demosaic
engine, see `PROJECT_BRIEF.md`) and darktable's own demosaic/color pipeline are different
implementations that will never agree pixel-for-pixel upstream of filmic, regardless of whether
the filmic port itself is correct. This harness instead checks the two things that actually
isolate whether the *port* is correct:

1. **Struct layout**: `decode_darktable_params.py` decodes the real, darktable-authored
   `filmicrgb` module params from the reference XMP fixture (`~/Pictures/test/_MG_1633.CR2.xmp`)
   — a gzip-compressed, base64-encoded C struct blob. Getting every field's name, order, and
   type right was verified by successfully decoding real field data into physically sane,
   in-range values (see field dump below) — not guessed from documentation.
2. **Curve math on real numbers**: those decoded values (this photographer's actual black/white
   points, latitude, contrast, balance) are fed into our Swift `FilmicSpline.compute()` — the
   exact same function the live preview uses — via
   `RawEngineTests.filmicSplineMatchesRealDarktableEditContinuity()`. This checks the resulting
   curve is well-formed (continuous, monotonic, endpoints land on the target black/white
   display values) using parameters this app didn't choose, a real editor did.

What's *not* verified: bit-exact agreement with darktable's own arithmetic (would need to
instrument darktable's C code to dump its internal spline coefficients, which wasn't in scope
this session) or a full-pipeline pixel diff (see above — not meaningful given the demosaic
difference). The visual side-by-side below is a sanity check, not a pass/fail gate.

## Reproducing

```bash
# 1. Render darktable's authentic output for the real edit (isolated config, per PROJECT_BRIEF.md):
DT_APP="/Applications/darktable 2.app/Contents/MacOS/darktable-cli"
WORK=/tmp/dt_harness
mkdir -p "$WORK/config" "$WORK/cache" "$WORK/out"
"$DT_APP" ~/Pictures/test/_MG_1633.CR2 ~/Pictures/test/_MG_1633.CR2.xmp \
  "$WORK/out/reference.jpg" --core --configdir "$WORK/config" --cachedir "$WORK/cache"

# 2. Decode the real filmicrgb params from that same XMP:
python3 decode_darktable_params.py filmicrgb ~/Pictures/test/_MG_1633.CR2.xmp

# 3. Run RawEngineTests — includes a test that feeds those exact decoded numbers through
#    FilmicSpline.compute() and checks the curve is well-formed:
swift test --package-path ../.. --filter filmicSplineMatchesRealDarktableEditContinuity
```

## Reference field dump

Decoded from `~/Pictures/test/_MG_1633.CR2.xmp`, `filmicrgb` module, `modversion="6"` (matches
`DT_MODULE_INTROSPECTION(6, dt_iop_filmicrgb_params_t)` in `release-5.6.0` exactly):

```
black_point_source = -7.65        white_point_source = 4.56
output_power        = 3.6148       latitude            = 0.01
contrast             = 1.0         balance             = 0.0
spline_version       = 2 (V3)      shadows/highlights   = 0/0 (poly4)
preserve_color       = 3 (POWER_NORM — not the mode this port implements, see FilmicRGBParameters)
version              = 4 (COLORSCIENCE_V5 — not the mode this port implements)
```

`spline_version == 2` (V3) and `shadows`/`highlights == 0` (poly4) match this port's scope
exactly. `preserve_color`/`version` don't — that's the documented, deliberate scoping decision
in `FilmicRGBParameters`, not a bug.

---

## Color Balance RGB (Phase 4)

Same approach, same caveat about full-pipeline pixel diffs not being meaningful (different
demosaic engine, see above) — plus one more: this port additionally skips darktable's D50 ICC
profile round-trip (assumes the pipeline is already linear sRGB/Rec709 at D65, see
`ColorBalanceRGBParameters`) and the entire perceptual saturation/brilliance stage (JzAzBz or
darktable's "UCS 22" colorspace — a user-confirmed scoping decision for this session, not an
oversight). So even a same-parameters, same-demosaic comparison would only be expected to agree
on the parts this port actually implements: the 4-way wheels, opacity masks, hue rotation,
linear chroma boost + vibrance, and fulcrumed contrast.

1. **Struct layout**: `decode_darktable_params.py colorbalancergb <xmp>` decodes the real
   `colorbalancergb` module params from the same reference XMP fixture — 132 bytes, matching
   `DT_MODULE_INTROSPECTION(5, dt_iop_colorbalancergb_params_t)` exactly. Confirmed correct by
   decoding into physically sane values (see dump below).
2. **Identity at defaults**: `ColorBalanceRGBTests.defaultParametersAreIdentity()` — with all 4
   wheels neutral (darktable's shipped defaults), the whole pipeline should reduce to the
   identity function on any non-negative RGB triplet. This is the single strongest self-check
   available for a module this size: every stage (opacity masks, hue rotation, chroma boost,
   color balance, midtones power, contrast) has to independently reduce to a no-op for this to
   pass, so it exercises nearly the entire port at once.
3. **Real edit cross-check**: `matchesRealDarktableEditForUnimplementedFieldsGracefully()` feeds
   this port's Swift reference (`ColorBalanceRGBProcessor.apply`) the real edit's
   `chroma_global`/`mask_grey_fulcrum`/`grey_fulcrum` values and checks the output stays finite
   and non-negative — a weaker check than Phase 3's, because that real edit's only non-zero
   fields (`saturation_global`, `chroma_global`) partly land in the skipped perceptual stage.
4. **CIKernel actually runs**: `colorBalanceRGBRendersAndDiffersFromPassthrough` /
   `...ExportProducesReadableJPEG` render the real CR2 through the GPU kernel end-to-end.

### Reproducing

```bash
python3 decode_darktable_params.py colorbalancergb ~/Pictures/test/_MG_1633.CR2.xmp
swift test --package-path ../.. --filter ColorBalanceRGB
```

### Reference field dump

Decoded from `~/Pictures/test/_MG_1633.CR2.xmp`, `colorbalancergb` module, `modversion="5"`:

```
shadows/midtones/highlights/global Y,C,H = all 0.0   (wheels untouched in this edit)
shadows_weight = 1.0    highlights_weight = 1.0
chroma_global = 0.0914   saturation_global = 0.1827  (perceptual — not implemented this phase)
mask_grey_fulcrum = 0.1845   grey_fulcrum = 0.1845    (both match this port's defaults exactly)
saturation_formula = 1  (darktable UCS 22 — confirms it really is the shipped default,
                          not JzAzBz; this port implements neither, per the user's explicit
                          scoping choice for this phase)
```
