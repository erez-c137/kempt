# Kempt brand: the shipped icons and the research behind them

Index for this folder. The icons that actually ship live in `plasmoid/contents/icons/`, not here;
everything in `docs/research/brand/` is the reasoning, the measurements and the evidence.

## What ships, and where

`plasmoid/contents/icons/` is a flat directory with five hand-authored SVGs.

| File | What it is | Installed as |
| --- | --- | --- |
| `kempt.svg` | full-colour app icon, fine comb, 17 elements | `~/.local/share/icons/hicolor/scalable/apps/kempt.svg` |
| `kempt-48.svg` | full-colour app icon, mid comb, 7 elements | `.../hicolor/64x64/apps/kempt.svg` and `.../48x48/apps/kempt.svg` |
| `kempt-32.svg` | full-colour app icon, six-tooth drawing | `.../hicolor/32x32/`, `22x22/` and `16x16/apps/kempt.svg` |
| `kempt-symbolic.svg` | monochrome panel glyph, 22 px, five teeth | resolved by its own name, not part of the ladder |
| `kempt-symbolic-16.svg` | monochrome panel glyph, 16 px, five teeth | resolved by its own name, not part of the ladder |

`install.sh` installs the three full-colour drawings, all under the single name `kempt`, and
removes all six files on `--uninstall`. `--destdir` stages the same ladder under a prefix.

## The ladder

| Requested size | Directory | Drawing | Teeth | Verdict, measured |
| --- | --- | --- | --- | --- |
| 96 px and up | `scalable/apps` | `kempt.svg` | 15 fine + 2 tapered ends | crisp at 128 and 256 |
| 64 px | `64x64/apps` | `kempt-48.svg` | 5 fine + 2 tapered ends | crisp, zero half-tones |
| 48 px | `48x48/apps` | `kempt-48.svg` | 5 fine + 2 tapered ends | even, 2 solid px per tooth and gap |
| 32 px | `32x32/apps` | `kempt-32.svg` | 6, flush ends | crisp, zero half-tones |
| 22 px | `22x22/apps` | `kempt-32.svg` | 6, flush ends | smeared, see the open problem below |
| 16 px | `16x16/apps` | `kempt-32.svg` | 6, flush ends | collapses to a flat bar, see below |

**One name resolves to all of them.** An XDG icon theme picks the directory whose declared size
matches the request, and `/usr/share/icons/hicolor/index.theme` lists every fixed-size directory
before `scalable/apps`, so an exact-size directory always wins over the scalable one. This was not
taken on faith. Verified on this box (Fedora 44, Plasma 6.7):

- `kiconfinder6 kempt` returns `~/.local/share/icons/hicolor/48x48/apps/kempt.svg`, not the
  scalable file, at its default lookup size.
- `QIcon.fromTheme("kempt")` reports `availableSizes` of 16, 22, 32, 48, 64, 128 (the 128 is the
  `Size=128` that `hicolor` declares for `scalable/apps`), and the pixmap it returns at each size
  is byte-for-byte the render of the drawing named in the table above: 16, 22 and 24 px get
  `kempt-32.svg`, 48 and 64 get `kempt-48.svg`, and 96, 128 and 256 get `kempt.svg`.
- Breeze itself is laid out the same way: `/usr/share/icons/breeze/apps/` holds `16`, `22`, `24`,
  `32`, `48` and `64` as separate directories of separate drawings, which is the pattern this
  ladder copies.

## The 2026-08-26 decision

**The app icon should look like the founder's reference photo at the sizes where it can, and stay
the six-tooth pictogram where pixels force it.** This supersedes the assumption behind the earlier
work, which was that one drawing would serve every size. It does not: a comb fine enough to read
as a comb at 128 px has 1 px teeth at 32, and the six-tooth drawing that is exact at 32 px is a
coarse fence at 256.

The founder's reference is `candidates/source-comb-slate-cream.jpg`, and the reason he chose it is
**the ends**: the spine cuts diagonally down to the outermost teeth, so a wedge of slate opens
beside each end tooth. That is what makes the drawing read as a comb rather than as a fence, and
it is mandatory in `kempt.svg`, reproduced from measurement. It is kept in `kempt-48.svg` too,
steepened to 45 degrees, because a 15 degree cut moves less than one device pixel at 48 px and
vanishes. The six-tooth drawing keeps its flush ends and is otherwise untouched.

## What was measured off the source photo

Measured with PIL on `candidates/source-comb-slate-cream.jpg`, not eyeballed. The tile in that
JPEG is 706 x 719 px and the comb inside it is 464 x 154 px.

| Property | Source | `kempt.svg` (256 grid) | `kempt-48.svg` (256 grid) |
| --- | --- | --- | --- |
| Comb width, as % of tile | 65.72% | 68.75% (176 u) | 87.50% (224 u) |
| Comb height, as % of tile | 21.42% | 21.88% (56 u) | 25.00% (64 u) |
| Comb aspect | 3.01 : 1 | 3.14 : 1 | 3.50 : 1 |
| Comb centring | dx 0, dy +0.35% | centred | centred |
| Spine height, as % of comb | 33.77% | 35.71% (20 u) | 37.50% (24 u) |
| Spine top corner radius, as % of comb height | 9.09% | 8.93% (r=5) | 12.50% (r=8) |
| Elements (fine teeth + end teeth) | 16 (14 + 2) | 17 (15 + 2) | 7 (5 + 2) |
| Fine tooth width, as % of comb width | 2.12% | 2.27% (4 u) | 7.14% (16 u) |
| Gap, as % of comb width | 3.98% | 3.41% (6 u) | 7.14% (16 u) |
| Pitch, as % of comb width | 6.10% | 5.68% (10 u) | 14.29% (32 u) |
| Gap : fine tooth | 1.87 : 1 | 1.50 : 1 | 1.00 : 1 |
| End tooth at the spine, vs a fine tooth | 2.43 x | 2.50 x (10 u) | 1.50 x (24 u) |
| End tooth at the tip, vs a fine tooth | 1.22 x | 1.50 x (6 u) | 0.75 x (12 u) |
| End taper angle, off vertical | 14.93 deg | **14.93 deg** | 45 deg |
| End taper starts, % down the teeth | 52.0% | 50.0% | 55.0% |
| Tooth tips | semicircular, r = half the tooth | same (r=2) | same (r=8) |

Raw measurements: the comb's fine teeth measure 9.86 px wide on average (min 9, max 10) with
18.46 px gaps at a 28.31 px pitch; the end teeth are 24 px at the spine and taper on their **outer
side only** (the inner edge never moves), 12 px of inset over 45 rows, ending 12 px wide before
the tip cap.

### The deliberate deviations, and why

Every coordinate in `kempt.svg` is **even**. At 128 px the scale is exactly 0.5, so an even
coordinate is a whole device pixel and an odd one is a smeared half. That single constraint is
what costs the two proportions that miss:

- **Gap : tooth is 1.50 instead of 1.87.** A 4-unit tooth with a 7-unit gap would match the source,
  but pitch 11 puts every tooth edge on a half-pixel at 128 px.
- **The comb is 68.75% of the tile wide instead of 65.72%.** 176 units is what fits 15 teeth at
  pitch 10 while keeping the end teeth at 2.5 x a fine tooth on an even grid, and it is also the
  footprint the 32/22/16 drawing already uses.

`kempt-48.svg` deviates much further, and has to. 48 px is 3/16 of the 256 grid, so a coordinate is
a whole device pixel only at multiples of 16, and an element narrower than 16 units cannot show two
solid device pixels. 16-unit teeth with 16-unit gaps is therefore the floor, which fixes the pitch
and leaves only the comb width free: 224 units is what fits seven of them. The comb widening as the
icon shrinks is optical sizing, the same thing Breeze does when its 16 px drawings fill more of
their box than its 64 px ones.

## Evidence

- `2026-08-26-icon-ladder-sheet.png` - the ladder at true size on Breeze Light and Breeze Dark,
  the source photo next to the redraw at 128 px, a matched-scale crop of the end taper (source vs
  redraw, side by side, plus 2x magnifications), and the pixel rows behind every claim above.
- `2026-08-25-icon-verdict.md` - the binding candidate verdict, the redraw specification, the
  flush-ends and six-teeth decision, and the appendix recording this ladder decision.
- `candidates/legibility/kempt-svg/final-sheet.png` - the six-tooth drawing at 128/64/48/32.
- `candidates/legibility/kempt-svg/comparison-ends.png` - the earlier overhang-vs-flush pair.
- `legibility-sheet-round1.png`, `legibility-sheet-round2.png` - the original bake-off sheets.
- `kempt-a-comb-arrow.svg`, `kempt-b-comb.svg` - the hand-drawn 16 px-grid concepts.
- `candidates/` - the raw generated explorations, including the three source images. Nothing in
  that folder ships; see `candidates/README.md`.

## Open problem: 22 and 16 px

The six-tooth drawing is **exact** at 32 px: its 176 units of comb map to 22 device pixels, so
every tooth is 2 px of solid cream and every gap 2 px of solid slate, with no antialiased
half-tone anywhere in a row through the teeth.

It does not survive the two sizes below that. At 22 px the same comb maps to 15.1 px for 11
elements and at 16 px to 11 px for 11 elements - one device pixel per element, landing on
half-pixel boundaries, which blends to a single flat bar. A row through the teeth at 16 px reads
`242` all the way across: the teeth are gone.

This is **not a regression**. Before the ladder the scalable file *was* the six-tooth drawing, so a
16 px request already rendered exactly like this. It is also not what the system tray shows: the
tray uses `kempt-symbolic.svg` / `kempt-symbolic-16.svg`, which are hand-hinted for 22 and 16 px
(five teeth, 2 px wide with 1 px gaps) and are untouched by the ladder.

Fixing it needs a fourth rung: a hand-hinted small drawing on the same principle as the symbolic
glyphs. That is a new drawing, not an edit to the six-tooth one, and it was out of scope for the
2026-08-26 decision.
