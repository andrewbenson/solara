#!/bin/sh
set -eu
case "${1-}" in
  --help|-h)
    cat <<'HELP'
Usage: docs/brand/solara/build.sh
Regenerate Solara Classic and Calm app assets, Raycast's icon, Chromium
product logos and favicons, and the macOS notification helper's icons.
Requires macOS, python3, librsvg's rsvg-convert, iconutil and Xcode's
actool and assetutil. Run from any directory. No app or engine build runs.
HELP
    exit 0
    ;;
  '') ;;
  *) printf '%s\n' "Unknown argument: $1" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  printf '%s\n' 'Expected no arguments; use --help for usage.' >&2
  exit 2
fi
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$source_dir" <<'PY'
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
root = source.parents[2]
for name in ('rsvg-convert', 'iconutil', 'xcrun'):
    if not shutil.which(name):
        raise SystemExit(f'Missing required tool: {name}')
for name in ('actool', 'assetutil'):
    subprocess.run(['xcrun', '--find', name], check=True, stdout=subprocess.DEVNULL)
engine = root / 'engine/chromium/src'
theme = engine / 'chrome/app/theme'
app = root / 'apps/browser/macos/Solara-macOS/Assets.xcassets'
classic = app / 'SolaraIcon.appiconset'
calm = app / 'SolaraCalm.imageset'

def render(svg, pixels, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['rsvg-convert', '-w', str(pixels), '-h', str(pixels), '-o', str(output), str(svg)], check=True)

def master(pixels):
    for size in (16, 32, 64, 128):
        if pixels <= size:
            return source / f'classic-{size}.svg'
    return source / 'classic.svg'

def copy(origin, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(origin, destination)

def catalog_info(path):
    result = subprocess.run(['xcrun', 'assetutil', '--info', str(path)], check=True, capture_output=True, text=True)
    entries = json.loads(result.stdout)
    for entry in entries:
        entry.pop('Timestamp', None)
    return entries

with tempfile.TemporaryDirectory(prefix='.solara-brand-', dir=root) as directory:
    scratch = Path(directory)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            render(master(pixels), pixels, classic / f'icon_{points}x{points}_{scale}x.png')
    render(source / 'classic.svg', 512, root / 'apps/browser/assets/app-icon-solara.png')
    for pixels in (512, 1024):
        render(source / 'calm.svg', pixels, calm / f'calm_{pixels}.png')
    render(source / 'classic.svg', 512, root / 'extras/raycast-solara/assets/icon.png')
    iconset = scratch / 'AppIcon.iconset'
    iconset.mkdir()
    for points in (16, 32, 128, 256):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            copy(classic / f'icon_{points}x{points}_{scale}x.png', iconset / f'icon_{points}x{points}{suffix}.png')
    mac = theme / 'chromium/mac'
    subprocess.run(['iconutil', '--convert', 'icns', '--output', str(scratch / 'app.icns'), str(iconset)], check=True)
    copy(scratch / 'app.icns', mac / 'app.icns')
    catalog = scratch / 'Assets.xcassets'
    appicon = catalog / 'AppIcon.appiconset'
    appicon.mkdir(parents=True)
    info = {'author': 'xcode', 'version': 1}
    (catalog / 'Contents.json').write_text(json.dumps({'info': info}, indent=2) + '\n')
    images = []
    for points in (16, 32, 128):
        for scale in (1, 2):
            name = f'icon_{points}x{points}_{scale}x.png'
            copy(classic / name, appicon / name)
            images.append({'filename': name, 'idiom': 'mac', 'scale': f'{scale}x', 'size': f'{points}x{points}'})
    (appicon / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2) + '\n')
    compiled = scratch / 'compiled'
    compiled.mkdir()
    command = ['xcrun', 'actool', str(catalog), '--compile', str(compiled), '--platform', 'macosx',
               '--minimum-deployment-target', '13.0', '--app-icon', 'AppIcon',
               '--output-partial-info-plist', str(compiled / 'partial.plist')]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(result.returncode)
    new_car = compiled / 'Assets.car'
    old_car = mac / 'Assets.car'
    if not old_car.exists() or catalog_info(new_car) != catalog_info(old_car):
        copy(new_car, old_car)
    slots = {}
    def logo(path, pixels):
        slots[theme / path] = pixels
    for pixels in (16, 24, 48, 64, 128, 256):
        logo(f'chromium/product_logo_{pixels}.png', pixels)
    for scale in (1, 2):
        density = f'default_{scale}00_percent'
        for points in (16, 32):
            logo(f'{density}/chromium/product_logo_{points}.png', points * scale)
        for name in ('product_logo_name_22', 'product_logo_name_22_white'):
            logo(f'{density}/chromium/{name}.png', 22 * scale)
        logo(f'{density}/common/favicon_ntp.png', 16 * scale)
        components = engine / f'components/resources/{density}/chromium'
        slots[components / 'favicon_product.png'] = 16 * scale
        for name in ('product_logo', 'product_logo_white'):
            slots[components / f'{name}.png'] = 32 * scale
    for pixels in sorted(set(slots.values()) | {256}):
        svg = master(pixels).read_text()
        viewbox = '100 100 824 824' if pixels <= 64 else '86.7 86.7 850.6 850.6' if pixels == 128 else '72.5 72.5 878.9 878.9'
        svg = re.sub(r'viewBox="[^"]+"', f'viewBox="{viewbox}"', svg, count=1)
        svg = re.sub(r' filter="url\(#[^\"]+-sh\)"', '', svg)
        if pixels == 256:
            svg = re.sub(r' width="\d+" height="\d+"', ' width="256" height="256"', svg, count=1)
            svg = svg.replace('classic-sun115-x-1024', 'solara-256')
            for name in ('product_logo.svg', 'product_logo_animation.svg'):
                (theme / 'chromium' / name).write_text(svg)
        svg_path = scratch / f'product-{pixels}.svg'
        png_path = svg_path.with_suffix('.png')
        svg_path.write_text(svg)
        render(svg_path, pixels, png_path)
        for path, size in slots.items():
            if size == pixels:
                copy(png_path, path)
    copy(source / 'mono-22.png', theme / 'chromium/product_logo_22_mono.png')
print('Regenerated Solara app, Raycast, engine logos and notification-helper icons.')
PY
