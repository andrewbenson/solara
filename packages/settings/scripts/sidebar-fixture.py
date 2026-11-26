import argparse
import base64
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument('spec')
parser.add_argument('support')
args = parser.parse_args()
spec = json.loads(Path(args.spec).read_text())
support = Path(args.support)
support.mkdir(parents=True, exist_ok=False)
repo = Path(__file__).resolve().parents[3]
fixtures = repo / 'packages/import/fixtures/home/Library/Application Support'
spaces = spec['spaces']

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False))

def link(item, parent):
    return dict(id=item['id'], parentID=parent, childrenIds=[], title=item.get('customTitle'), data=dict(tab=dict(savedURL=item['url'], savedTitle=item['title'])))

if spec['browser'] == 'arc':
    items = []
    models = []
    for space in spaces:
        roots = dict(pinned=space['id'] + '-pins', unpinned=space['id'] + '-open')
        models.append(dict(id=space['id'], title=space['name'], profile={'default': True} if space.get('profile', 'Default') == 'Default' else {'custom': {'_0': {'directoryBasename': space['profile']}}}, containerIDs=[part for pair in roots.items() for part in pair], customInfo=dict(iconType=dict(emoji_v2=space.get('emoji')), windowTheme=space.get('theme'))))
        def nodes(entries, parent):
            ids = []
            for item in entries:
                ids.append(item['id'])
                if 'url' in item:
                    items.append(link(item, parent))
                else:
                    children = nodes(item.get('children', []), item['id'])
                    data = {'list': {}}
                    if item.get('live'):
                        data = {'list': {'automaticLiveFolderData': {'github': {}}}}
                    items.append(dict(id=item['id'], parentID=parent, title=item['title'], childrenIds=children, data=data))
            return ids
        for kind, entries in [('pinned', space.get('pins', [])), ('unpinned', space.get('tabs', []))]:
            children = nodes(entries, roots[kind])
            items.append(dict(id=roots[kind], childrenIds=children, data={'itemContainer': {}}))
    favorites = spec.get('favorites', [])
    for item in favorites:
        items.append(link(item, 'favorites'))
    if favorites:
        items.append(dict(id='favorites', childrenIds=[item['id'] for item in favorites], data={'itemContainer': {}}))
    box = dict(spaces=models, items=items, topAppsContainerIDs=[{'default': True}, 'favorites'] if favorites else [])
    write(support / 'Arc/StorableSidebar.json', {'sidebar': {'containers': [{'global': {}}, box]}})
    profiles = list(dict.fromkeys(space.get('profile', 'Default') for space in spaces))
    write(support / 'Arc/User Data/Local State', {'profile': {'info_cache': {p: {'name': p} for p in profiles}, 'profiles_order': profiles, 'last_used': profiles[0]}})
    for profile in profiles:
        target = support / 'Arc/User Data' / profile
        write(target / 'Preferences', {'profile': {'name': profile}})
        if spec.get('icons'):
            shutil.copyfile(fixtures / 'Arc/User Data/Default/Favicons', target / 'Favicons')
        if spec.get('common'):
            shutil.copyfile(fixtures / 'Arc/User Data/Default/Bookmarks', target / 'Bookmarks')
            shutil.copyfile(fixtures / 'Arc/User Data/Default/History', target / 'History')
            with sqlite3.connect(target / 'History') as db:
                db.execute('UPDATE urls SET last_visit_time = ?', ((time.time() + 11644473600) * 1000000,))
                db.commit()
else:
    root = support / 'zen'
    profile = root / 'Profiles/parity.default'
    profile.mkdir(parents=True)
    (root / 'profiles.ini').write_text('[Profile0]\nName=Parity\nIsRelative=1\nPath=Profiles/parity.default\nDefault=1\n')
    models = [dict(uuid=s['id'], name=s['name'], icon=s.get('emoji'), theme={'gradientColors': [{'c': '#00FF00', 'isPrimary': True}]}) for s in spaces]
    tabs = []
    for space in spaces:
        for pinned, entries in [(True, space.get('pins', [])), (False, space.get('tabs', []))]:
            for item in entries:
                tabs.append(dict(zenSyncId=item['id'], zenWorkspace=space['id'], pinned=pinned, zenStaticLabel=item.get('customTitle'), entries=[{'url': item['url'], 'title': item['title']}], index=1))
    for item in spec.get('favorites', []):
        tabs.append(dict(zenSyncId=item['id'], zenEssential=True, entries=[{'url': item['url'], 'title': item['title']}], index=1))
    raw = json.dumps(dict(spaces=models, tabs=tabs, isPrivate=spec.get('modernPrivate', False))).encode()
    extra = len(raw) - 15
    block = bytes([min(len(raw), 15) << 4])
    if extra >= 0:
        block += bytes([255]) * (extra // 255) + bytes([extra % 255])
    (profile / 'zen-sessions.jsonlz4').write_bytes(b'mozLz40\0' + struct.pack('<I', len(raw)) + block + raw)
