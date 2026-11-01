# Solara artwork

Solara's app icon is “Outrun Classic”: a striped synthwave sun half set over a magenta horizon above a neon grid,
on a deep violet sky. The sun is 15% larger than the first cut (the owner's pick, 2026-10-24), still half set on
the same horizon. `classic.svg` is the 1024 px master, drawn as Apple's template: an 824 px squircle at a 100 px
inset with a soft shadow. `classic-{128,64,32,16}.svg` are hand-simplified small masters.

## Build every icon and engine logo

From any directory, run `docs/brand/solara/build.sh` (use its absolute path outside the repository).
`docs/brand/solara/build.sh --help` prints usage. It needs macOS, Python 3, `rsvg-convert` (Homebrew's `librsvg`),
`iconutil`, and Xcode's `xcrun actool` and `xcrun assetutil`. It runs locally, with no app or engine build, network,
Pillow or NumPy. Temporary catalog and iconset inputs are removed on exit.

App PNGs come from the nearest master for each pixel size:

| Pixels | Source | Classic appiconset files |
|---|---|---|
| 16 | `classic-16.svg` | `icon_16x16_1x.png` |
| 32 | `classic-32.svg` | `icon_16x16_2x.png`, `icon_32x32_1x.png` |
| 64 | `classic-64.svg` | `icon_32x32_2x.png` |
| 128 | `classic-128.svg` | `icon_128x128_1x.png` |
| 256 | `classic.svg` | `icon_128x128_2x.png`, `icon_256x256_1x.png` |
| 512 | `classic.svg` | `icon_256x256_2x.png`, `icon_512x512_1x.png` |
| 1024 | `classic.svg` | `icon_512x512_2x.png` |

Appiconsets are under `apps/browser/macos/Solara-macOS/Assets.xcassets/`. The app selects `SolaraIcon` with
`AC_APP_ICON = SolaraIcon` (`docs/releasing.md` → The app's identity).

## Generated slots

Engine paths below are relative to `engine/chromium/src/`. At 200%, the filenames retain their point-size names;
the PNG dimensions double.

| Output slot | Pixels / source | Use |
|---|---|---|
| `apps/browser/macos/Solara-macOS/Assets.xcassets/SolaraIcon.appiconset/*.png` | table above | Classic bundle icon, including Dock and Finder |
| `apps/browser/assets/app-icon-solara.png` | 512, `classic.svg` | Solara's in-app brand image |
| `apps/browser/macos/Solara-macOS/Assets.xcassets/SolaraCalm.imageset/calm_{512,1024}.png` | 512 and 1024, `calm.svg` | Settings → Appearance → App Icon → Calm |
| `extras/raycast-solara/assets/icon.png` | 512, `classic.svg` | Raycast extension icon |
| `chrome/app/theme/chromium/mac/app.icns` | 16, 32, 128, 256 pt, each @1x and @2x; Classic template PNGs | Chromium Framework's Alerts helper: web notifications and System Settings → Notifications |
| `chrome/app/theme/chromium/mac/Assets.car` | `AppIcon`, exactly 16, 32, 128 pt @1x and @2x | The same helper's asset-catalog icon lookup |
| `chrome/app/theme/chromium/product_logo_{16,24,48,64,128,256}.png` | each filename's pixel size | Chromium `IDR_PRODUCT_LOGO_*`: About, version, profile picker, task manager, screen-sharing, payment and sign-in dialogs |
| `chrome/app/theme/chromium/product_logo{,_animation}.svg` | 256 square vector | Chromium vector product logo slots; both are the same static Classic tile |
| `chrome/app/theme/chromium/product_logo_22_mono.png` | 22, preserved `mono-22.png` source | Existing monochrome product mark |
| `chrome/app/theme/default_{100,200}_percent/chromium/product_logo_{16,32}.png` | 16/32 at 100%, 32/64 at 200% | Scaled Chromium product resources, including framework `Resources/product_logo_32.png` |
| `chrome/app/theme/default_{100,200}_percent/chromium/product_logo_name_22{,_white}.png` | 22 at 100%, 44 at 200% | Chromium wordmark slots, rendered as the colored tile alone; Solara has no wordmark |
| `chrome/app/theme/default_{100,200}_percent/common/favicon_ntp.png` | 16 at 100%, 32 at 200% | Engine New Tab favicon |
| `components/resources/default_{100,200}_percent/chromium/favicon_product.png` | 16 at 100%, 32 at 200% | Component product favicon (`IDR_PRODUCT_FAVICON`) |
| `components/resources/default_{100,200}_percent/chromium/product_logo{,_white}.png` | 32 at 100%, 64 at 200% | Component product logos; both variants use the colored tile |

There is no `chrome/app/theme/chromium/product_logo.png` in this checkout; the unnumbered PNGs live under
`components/resources`. The `_name_22`, `_name_22_white`, and component `_white` slots already contain colored
Classic tiles, so their names do not imply a new monochrome treatment.

### Preserve the engine's existing optical crops

Product logos remove only the template body rectangle's drop-shadow filter; the sky, sun, grid, glow and rim
remain. The current artwork uses tighter crops at smaller sizes, rather than one uniform 92% tile:

| Output pixels | Master | SVG viewBox | Tile width as share of square |
|---|---|---|---|
| 16 | `classic-16.svg` | `100 100 824 824` | 100% |
| 22, 24, 32 | `classic-32.svg` | `100 100 824 824` | 100% |
| 44, 48, 64 | `classic-64.svg` | `100 100 824 824` | 100% |
| 128 | `classic-128.svg` | `86.7 86.7 850.6 850.6` | about 96.87% |
| 256 / SVG | `classic.svg` | `72.5 72.5 878.9 878.9` | about 93.75% |

Those crops reproduce the existing colored logos. Sizes between small masters use the next larger small
master. `mono-22.png` preserves the existing mono raster exactly: its original construction is unknown, so it
is an explicit source instead of a newly interpreted mark.

### Helper icon identity

The catalog is deliberately named `AppIcon.appiconset`, compiled with `--app-icon AppIcon`, and checked with
`assetutil` for six icon renditions named `AppIcon`. The deployment target stays macOS 13.0. The ICNS is built
separately with `iconutil` so it can also contain the 256 pt @1x/@2x pair without adding catalog renditions.

This repository is an overlay, not a full Chromium source tree. It has neither `chrome/app/helper-Info.plist`
nor the upstream app-mode Info.plists. `engine/patches/chromium-helper-name.patch` references the helper plist
and changes only its display name; it does not change the icon keys. Keeping the existing catalog name
`AppIcon` and filename `app.icns` preserves the helper's icon lookup contract, including `CFBundleIconName`
lookups for `AppIcon`. No plist or helper identity change is needed.

`engine/chromium/apply.sh` copies these overlay assets into Chromium. The generated engine assets ship after
the owner's next engine resource/helper rebuild; running this script alone does not update an installed app.
`Assets.car` is a compiled Xcode artifact; toolchain versions can change its bytes without changing the images.

## Calm

Calm has the same sky, squircle, rim and shadow as Classic, with no floor, grid, horizon band or horizon line.
Its sun is whole: a striped circle at 78% of Classic's radius (255.7, the owner's pick, 2026-10-27), centred at
y 512 with 157 px of sky on every side. The gradient spans the full disc. Its glow and stripe gaps scale with
it; the gaps sit in the lower half, with the bars thinning toward a small bottom cap.

Settings offers Calm (`calm`) beside Classic (`default`, the bundle icon). `AppIcons` draws it at runtime from
`SolaraCalm.imageset`, so the script renders only `calm.svg` at 512 and 1024 px. The hand-simplified
`calm-{128,64,32,16}.svg` masters remain available for future bundle or document icons.

## Slots the script doesn't write

| Slot | Use |
|---|---|
| `apps/browser/assets/solara/ntp-mark[-<colour>]-sun[@2x,@3x].png` | The New Tab page's rising sun, one per profile colour; the `-back` and `-front` layers beside them are empty |
| `apps/browser/assets/solara/new-tab-mark{,@2x,@3x}.png` | The one-colour sun (a half disc over two bars) on the sidebar's and the strip's New Tab row, drawn tinted |
| `scripts/dmg/app-icon.png` | The DMG background's header icon; `scripts/dmg/render.sh` renders it from `classic.svg` at 256 px before drawing the background |
