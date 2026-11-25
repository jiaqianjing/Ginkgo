#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lists Chinese string literals in the app that the compiler does not treat as localizable.

Build the app first (SWIFT_EMIT_LOC_STRINGS is on in project.yml), then run:
    python3 scripts/check-localization.py <DerivedData path>
Every literal containing Chinese must be a LocalizedStringKey / String(localized:) site, i.e. appear in a
.stringsdata file at its line. Debug-only fixtures (DebugLaunch.swift) and lines marked
`l10n-ignore` (e.g. language names written in their own language) are skipped. Exit code 1 if any are left.
It also reports catalog keys missing an English translation.
"""
import json, os, re, sys

root = os.path.join(os.path.dirname(__file__), '..', 'App')
derived = sys.argv[1]
sites = set()
for dp, _, fs in os.walk(derived):
    if 'Ginkgo.build' not in dp or 'GinkgoKit' in dp:
        continue
    for f in fs:
        if f.endswith('.stringsdata'):
            d = json.load(open(os.path.join(dp, f), encoding='utf-8'))
            for entry in d.get('tables', {}).get('Localizable', []):
                sites.add((os.path.realpath(d['source']), entry['location']['startingLine']))

han = re.compile(r'[一-鿿]')
lit = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
left = 0
for dp, _, fs in os.walk(os.path.join(root, 'Ginkgo')):
    for f in sorted(fs):
        if not f.endswith('.swift') or f == 'DebugLaunch.swift':
            continue
        path = os.path.realpath(os.path.join(dp, f))
        for i, line in enumerate(open(path, encoding='utf-8'), 1):
            if line.strip().startswith('//') or 'l10n-ignore' in line:
                continue
            if any(han.search(m.group(1)) for m in lit.finditer(line)) and (path, i) not in sites:
                print(f'{os.path.relpath(path)}:{i}: {line.strip()[:140]}')
                left += 1

catalog = json.load(open(os.path.join(root, 'Ginkgo', 'Localizable.xcstrings'), encoding='utf-8'))
missing = [k for k, v in catalog['strings'].items()
           if k and v.get('shouldTranslate', True) and 'en' not in v.get('localizations', {})]
for k in missing:
    print(f'no English: {k!r}')
print(f'{left} literal(s) not localizable, {len(missing)} key(s) without English')
sys.exit(1 if left or missing else 0)
