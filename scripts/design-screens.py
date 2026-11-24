#!/usr/bin/env python3
"""Capture simulator renders with in-memory sample data. Run on a simulator without provider keys: original before/demoInk paths can invoke AI."""
import argparse
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--device', default='booted')
parser.add_argument('--group', choices=['library', 'portrait', 'landscape', 'states', 'accessibility', 'before', 'reader-all'], required=True)
parser.add_argument('--appearance', choices=['light', 'dark'])
parser.add_argument('--only', help='Capture only these comma-separated state names')
parser.add_argument('--output', type=Path, default=Path('docs/design/screens'))
a = parser.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
bundle = 'com.kenjia.ginkgo'
def sim(*args, check=True):
    return subprocess.run(['xcrun', 'simctl', *args], check=check, capture_output=True, text=True, timeout=30)

def capture(name, args, appearance):
    sim('terminate', a.device, bundle, check=False)
    sim('ui', a.device, 'appearance', appearance)
    sim('ui', a.device, 'content_size', 'accessibility-extra-extra-extra-large' if 'accessibility' in name else 'large')
    sim('launch', a.device, bundle, '-inMemoryStore', 'YES', *args)
    time.sleep(5)
    sim('io', a.device, 'screenshot', str(a.output / f'{name}-{appearance}.png'))
    if 'landscape' in name:
        subprocess.run(['sips', '-r', '-90', str(a.output / f'{name}-{appearance}.png')], check=True, capture_output=True)
    print(f'{name}-{appearance}', flush=True)

seed = ['-seedSample', 'YES', '-openFirst', 'YES']
review = ['-demoMode', 'review']
def reader(fixture='overview', orientation='portrait'):
    return seed + ['-orientation', orientation, '-visualFixture', fixture]
groups = {
    'library': [('library-empty', []), ('library-populated', ['-seedSample', 'YES']), ('settings', ['-visualSettings', 'YES'])],
    'portrait': [('reader-portrait-reading', reader()), ('reader-portrait-review', reader() + review), ('selection-menu', reader('highlight') + ['-demoSelect', 'rather than one thing brilliantly']), ('highlight-menu', reader('highlight') + ['-visualHighlight', 'YES']), ('ask-sheet', reader() + ['-visualAsk', 'YES']), ('pen-banner', reader() + ['-demoInk', 'YES']), ('notes-panel', reader() + ['-demoNotes', 'YES'])],
    'landscape': [('reader-landscape-reading', reader(orientation='landscape')), ('reader-landscape-review', reader(orientation='landscape') + review), ('reader-landscape-handwriting', reader('handwriting', 'landscape') + review), ('reader-landscape-long', reader('long', 'landscape') + review)],
    'states': [(f'card-{state}', reader(state) + review) for state in ['pending', 'streaming', 'done', 'failed', 'handwriting', 'long']] + [('card-selected', reader('done') + review + ['-visualHighlight', 'YES'])],
    'accessibility': [('reader-accessibility-max', reader('done') + review), ('notes-accessibility-max', reader() + ['-demoNotes', 'YES']), ('selection-accessibility-max', reader('highlight') + ['-demoSelect', 'rather than one thing brilliantly']), ('pen-accessibility-max', reader() + ['-demoInk', 'YES'])],
    'before': [('before-library-empty', []), ('before-library-populated', ['-seedSample', 'YES']), ('before-reader-portrait-review', seed + ['-demoAnnotate', 'YES'] + review)]
}
groups['reader-all'] = sum((groups[group] for group in ['portrait', 'landscape', 'states', 'accessibility']), [])
original_appearance = sim('ui', a.device, 'appearance').stdout.strip()
original_size = sim('ui', a.device, 'content_size').stdout.strip()
try:
    sim('ui', a.device, 'content_size', 'accessibility-extra-extra-extra-large' if a.group == 'accessibility' else 'large')
    for appearance in ([a.appearance] if a.appearance else ['light', 'dark']):
        for name, args in groups[a.group]:
            if a.only and name not in a.only.split(','):
                continue
            capture(name, args, appearance)
finally:
    sim('ui', a.device, 'content_size', original_size, check=False)
    sim('ui', a.device, 'appearance', original_appearance, check=False)
