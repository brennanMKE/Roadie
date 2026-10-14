# Skin rendering compared with Webamp

Numbers only (#0026). `skintool --png` renders each skin's main window headless (SkinKit's `MainWindowRenderer`, no AppKit, no window) and, given reference screenshots, diffs it against the Winamp Skin Museum's Webamp rendering of the same skin. No images are committed: our PNGs, the references and the diffs live under `build/` (gitignored).

## Method

- **State.** Webamp's `?screenshot=1` state, as `MainWindowState.webampScreenshot`: playing, 0:03 of a 5 s track, 128 kbps / 44.1 kHz / stereo, marquee "1. DJ Mike Llama - Llama Whipping Intro (0:05)" at step 0, volume 78 %, balance centre, position 60 %, shuffle and repeat on, EQ and playlist open, bar visualizer with no data (background only), main window focused, shape clipped to `region.txt`.
- **References.** `https://r2.webampskins.org/screenshots/<md5 of the .wsz>.png`, 275x348 (main, EQ and playlist stacked); the top 116 rows are compared. All 19 sample skins have a Museum screenshot (md5 below), so there are no "no reference" rows.
- **Counts.** Pixels where both images are opaque. "exact" is any RGB difference; "±2" is a difference above 2 in some channel. "excl. vis" repeats both counts without the 76x16 visualizer rectangle at (24, 43). Pixels transparent in either image (outside the shape) are skipped.
- **Run.** `build/vm-tests/20261014-015015-95838/png/` (our `<name>.png` and `<name>.diff.png`, differing pixels magenta; `skintool-png.log` has the `diff` lines). Commands:

```bash
scripts/fetch-webamp-references.sh "untitled folder"     # host, once; needs network
scripts/run-tests-vm.sh --launch --skins "untitled folder" --references build/webamp-reference
```

## Results (19 skins)

| Skin | md5 | Reference | Exact px (of 31,900) | ±2 px | Exact excl. vis | ±2 excl. vis | Skipped transparent | What differs outside the vis |
|---|---|---|---|---|---|---|---|---|
| AmidalaAmp | `72cf0075385100e12eb9cc48435ddc77` | museum | 331 (1.04%) | 328 | 10 | 7 | 0 | NO_MINUS 5x1; marquee col 265 |
| Asian Dragon | `8f79cbc96c905c1db232d8c1a5cdbb70` | museum | 326 (1.02%) | 326 | 5 | 5 | 0 | NO_MINUS 5x1 |
| Bag_Ends_Gardener | `546dc4154dfa3e1ec605acf5de18a888` | museum | 327 (1.03%) | 327 | 6 | 6 | 0 | marquee col 265 |
| Carrie-Anne Moss | `b87082c4a409c9f7143bd1b75445ab26` | museum | 171 (0.54%) | 171 | 0 | 0 | 0 | vis only |
| Deus_AMP | `e4b7790cdd65fd53aed0c45ca4d619c8` | museum | 443 (1.39%) | 441 | 122 | 120 | 0 | NUMS_EX: NO_MINUS 9x13 cell drawn; marquee col 265 |
| Expensive_HI_FI_Sony_2005 | `6a2843f40058f86406630671b454d66b` | museum | 345 (1.12%) | 345 | 24 | 24 | 997 | region edge pixels (24 total, 4 of them NO_MINUS) |
| Internet_Archive_Winamp_Skin | `f86f47ed539e393678f805fe776e4d30` | museum | 360 (1.13%) | 327 | 39 | 6 | 0 | NUMS_EX: NO_MINUS 9x13 cell; marquee col 265 |
| Leeloo | `7a8b1409153f082cc73675509df0e084` | museum | 332 (1.04%) | 332 | 11 | 11 | 0 | NO_MINUS 5x1; marquee col 265 |
| Matrix_Code0110101 | `1a26146ab84438ed9f2f319b9424290b` | museum | 321 (1.01%) | 321 | 0 | 0 | 0 | vis only |
| Old_Mac-OS | `120427e1c5ddc12bfc907de3e75f3b66` | museum | 322 (1.01%) | 322 | 1 | 1 | 0 | NO_MINUS (1 px differs) |
| Pika_Amp | `061589029dde4c811f5c8013aae603d7` | museum | 349 (1.09%) | 349 | 28 | 28 | 25 | region edge pixels (28) |
| The_Hustler | `e678ecaff27d6818617c30832c8a227c` | museum | 335 (1.05%) | 335 | 14 | 14 | 0 | NUMS_EX: NO_MINUS cell (1 column differs); marquee col 265 |
| Winamp_Classic_CM | `ea984753761fc033254aa2dec64342c9` | museum | 356 (1.12%) | 356 | 35 | 35 | 0 | NUMS_EX: NO_MINUS 9x13 cell |
| Windows_Classic | `904772ab469987f911ad53325bb2538e` | museum | 327 (1.03%) | 327 | 6 | 6 | 0 | marquee col 265 |
| buffy1 | `d6fea8468d427c5cffb98f800b202fb4` | museum | 326 (1.02%) | 326 | 5 | 5 | 0 | NO_MINUS 5x1 |
| classic_mario | `442482547c94fe380f6441b09ed66c34` | museum | 322 (1.01%) | 322 | 1 | 1 | 0 | NO_MINUS (1 px differs) |
| makemesad | `e62de1bf659c92789e0467211414b8f3` | museum | 321 (1.01%) | 321 | 0 | 0 | 0 | vis only |
| nightcrawler_by_t_k | `90df3feb670e06da2990ffa05db626f7` | museum | 327 (1.03%) | 326 | 6 | 5 | 0 | marquee col 265 |
| v2_technics_white_resting_by_johnnyg0 | `b1fe1852c5ed7a3a2f4952f3b8cd7959` | museum | 332 (1.04%) | 332 | 11 | 11 | 0 | NO_MINUS 5x1; marquee col 265 |

Everything outside the visualizer is within 0 to 122 px per skin (0.4 % at most); three skins (Carrie-Anne Moss, Matrix, makemesad) match exactly there and two more (Old Mac-OS, classic_mario) are 1 px off. No sprite is misplaced, and the marquee, kbps/kHz, indicators, digits, sliders, toggles and transport buttons are pixel-identical wherever the difference counts are zero.

## Systematic differences

1. **Visualizer contents (321 px per skin; 171 for Carrie-Anne Moss): reference age.** The Museum's older screenshots show Webamp's dummy spectrum bars; a current Webamp, and ours, paints the bar background only (`getDummyVizData` has no consumer in the checked-out Webamp). Not a drawing difference; the rectangle is reported separately.
2. **`NO_MINUS_SIGN` drawn in elapsed mode: accepted.** We draw the no-minus sprite at the minus position as Winamp does (and as the app does); Webamp draws nothing there. NUMBERS skins differ by up to 5 px (the 5x1 bar at (38, 32)); NUMS_EX skins draw a 9x13 cell, 9 to 116 px (Deus_AMP 116, Winamp_Classic_CM 35, Internet_Archive 33, The_Hustler 9).
3. **Marquee column x = 265 (6 px in the eight skins whose text reaches it; The_Hustler 5): unexplained, accepted.** Webamp's screenshot shows text in the 155th column of the marquee box; we clip at the CSS width of 154 px (111 to 264). The Webamp CSS (`#marquee { width: 154px }`) does not account for it. Not chased.
4. **Region edge pixels (Expensive_HI_FI_Sony_2005 24 px, Pika_Amp 28 px; 997 and 25 pixels skipped as transparent): accepted.** The two shaped skins differ along the shape's edge: Chrome antialiases the CSS clip-path (edge pixels are partly transparent in the reference), we fill the polygon without antialiasing like the Win32 region (#0025). Counted premultiplied, so a half-transparent edge pixel counts as different.
5. **BMP decoding (ImageIO versus the browser): none seen.** Skins that match outside the items above match exactly (not just within ±2), so decoding and colour handling agree for these 24-bit files.

Found and fixed by this comparison (the plan's numbers were off): the marquee text sits at y 27, not 24 (`#marquee { top: 24px; padding: 3px 0 }` is a content-box, so the text is 3 px inside the 154x12 box; Winamp does the same), and the next button is 22 px wide (`#next { width: 22px }` clips the sprite's 23rd column). Both are in `MainWindowLayout`, which the app's views also read, so the app's marquee moves down 3 px and the next button loses a column with this change.

## Not covered

The EQ and playlist windows, the shade mode, a playing visualizer (needs audio), and pressed-button states are not rendered by `--png` yet. The numbers apply to the 1x main window only.
