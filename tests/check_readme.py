#!/usr/bin/env python3
"""Check a Codexion README.md against the subject's README requirements (v1.5).

Usage:
  check_readme.py PATH    a README.md file, or a directory: the README.md in it,
                          or in the nearest parent up to the git repository root

Checks:
  - the first line is italic and reads "This project has been created as part
    of the 42 curriculum by <login1>[, <login2>...]"
  - "Description", "Instructions" and "Resources" sections
  - the Resources section says how AI was used
  - the project-specific "Blocking cases handled" and
    "Thread synchronization mechanisms" sections
  - the topics those two sections are asked to cover (WARN when missing)

Only structure and keywords are checked: the content still needs a human
review, and the README must be written in English.

Exit status: 0 nothing failed, 1 a requirement is missing, 2 usage error.
"""
from pathlib import Path
import re
import subprocess
import sys

FIRST_LINE = re.compile(
    r'^\s*(\*|_)(?!\1)\s*This project has been created as part of the 42 curriculum by '
    r'[A-Za-z0-9][\w.-]*(\s*,\s*[A-Za-z0-9][\w.-]*)*\s*\.?\s*\1\s*$')

REQUIRED = [
    ('Description', r'description'),
    ('Instructions', r'instructions?'),
    ('Resources', r'resources?'),
    ('Blocking cases handled', r'blocking\s+cases(\s+handled)?'),
    ('Thread synchronization mechanisms', r'thread\s+synchroni[sz]ation(\s+mechanisms?)?'),
]

# Topics the subject lists for the two project-specific sections.
TOPICS = {
    'Blocking cases handled': [
        ('deadlock prevention', r'deadlock'),
        ("Coffman's conditions", r'coffman'),
        ('starvation prevention', r'starv'),
        ('cooldown handling', r'cool\s*-?down'),
        ('precise burnout detection', r'burn\s*-?out'),
        ('log serialization', r'(log|print|output)\w*.{0,80}(serial|mutex|lock|interleav)|'
                              r'(serial|mutex|lock|interleav)\w*.{0,80}(log|print|output)'),
    ],
    'Thread synchronization mechanisms': [
        ('mutexes (pthread_mutex_t)', r'pthread_mutex|\bmutex'),
        ('condition variables (pthread_cond_t)', r'pthread_cond|condition variable|\bcond\b'),
        ('race condition prevention', r'race'),
        ('coder/monitor communication', r'monitor'),
    ],
}


def find_readme(target):
    if target.is_file():
        return target
    try:
        top = subprocess.run(['git', '-C', str(target), 'rev-parse', '--show-toplevel'],
                             capture_output=True, text=True).stdout.strip()
    except OSError:
        top = ''
    folder = target.resolve()
    stop = Path(top).resolve() if top else folder
    while True:
        for name in ('README.md', 'readme.md', 'Readme.md'):
            if (folder / name).is_file():
                return folder / name
        if folder == stop or folder.parent == folder:
            return None
        folder = folder.parent


def sections(text):
    """List (lowercased heading, body) pairs; a body includes its subsections."""
    found = []
    in_code = False
    lines = text.splitlines()
    for number, line in enumerate(lines):
        if line.lstrip().startswith(('```', '~~~')):
            in_code = not in_code
        match = None if in_code else re.match(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$', line)
        if match:
            found.append((number, len(match.group(1)), match.group(2)))
    result = []
    for i, (number, level, title) in enumerate(found):
        end = next((n for n, lvl, _ in found[i + 1:] if lvl <= level), len(lines))
        clean = re.sub(r'[*_`]|\[([^\]]*)\]\([^)]*\)', r'\1', title).strip().lower()
        result.append((clean, '\n'.join(lines[number + 1:end])))
    return result


def check(path):
    text = path.read_text(errors='replace')
    fails = warns = 0
    first = next((line for line in text.splitlines() if line.strip()), '')
    if FIRST_LINE.match(first):
        print('OK: first line is the italic 42 curriculum credit')
    else:
        fails += 1
        print('FAIL: the first line must be italic and read "This project has been created as part '
              'of the 42 curriculum by <login1>[, <login2>...]"')
        print(f'      found: {first[:100]!r}')
    heads = sections(text)
    bodies = {}
    for name, pattern in REQUIRED:
        hits = [body for title, body in heads if re.search(r'\b' + pattern + r'\b', title)]
        if hits:
            bodies[name] = '\n'.join(hits)
            print(f'OK: section "{name}"')
        else:
            fails += 1
            print(f'FAIL: no "{name}" section heading')
    if 'Resources' in bodies:
        if re.search(r'\b(AI|artificial intelligence|LLM|ChatGPT|Claude|Copilot|Gemini)\b',
                     bodies['Resources'], re.I):
            print('OK: Resources section describes AI use')
        else:
            fails += 1
            print('FAIL: the Resources section must describe how AI was used (tasks and project parts)')
    for name, topics in TOPICS.items():
        body = bodies.get(name)
        if body is None:
            continue
        if len(body.split()) < 30:
            warns += 1
            print(f'WARN: "{name}" is very short ({len(body.split())} words)')
        for label, pattern in topics:
            if not re.search(pattern, body, re.I | re.S):
                warns += 1
                print(f'WARN: "{name}" does not mention {label}')
    print(f'INFO: checked {path} ({fails} failures, {warns} warnings); '
          'content and English wording still need a human review')
    return 1 if fails else 0


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    target = Path(argv[1])
    if not target.exists():
        print(f'ERROR: not found: {target}', file=sys.stderr)
        return 2
    readme = find_readme(target)
    if readme is None:
        print(f'FAIL: no README.md in {target} or its parents up to the repository root')
        return 1
    return check(readme)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
