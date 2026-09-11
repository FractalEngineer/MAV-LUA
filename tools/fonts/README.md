# Desktop preview fonts

These are unchanged bitmap font sheets from FreedomTX `Release_V1.40`:

- [STD](https://github.com/tbs-fpv/freedomtx/blob/Release_V1.40/radio/src/fonts/std/font_05x07.png)
- [SQT5](https://github.com/tbs-fpv/freedomtx/blob/Release_V1.40/radio/src/fonts/sqt5/font_05x07.png)

Copyright OpenTX contributors. The upstream font renderer declares GPL-2.0-or-later; these assets are redistributed under GPL-3.0-or-later with this project (see the root LICENSE). See [the upstream copyright/license notice](https://github.com/tbs-fpv/freedomtx/blob/Release_V1.40/radio/src/gui/128x64/fonts.cpp).

Each glyph occupies five columns and eight rows, starting at ASCII 32, sixteen glyphs per row. All-black (`0xff`) columns are proportional-width padding and are skipped by the firmware. One blank spacing column follows each glyph. Previews use these original pixels and a common baseline, without smoothing, rescaling individual glyphs or a desktop TrueType font. STD is the default; `--font sqt5` selects the alternate firmware font.

These files are desktop tooling only. The radio script uses `lcd.drawText` and ships no font assets.
