#!/usr/bin/env python3
"""Standard-library terminal selector; execution stays in run_tests.sh."""
import argparse
import curses
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent


def load_cases(path):
    cases = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = [part.strip() for part in line.split('|')]
        if len(fields) != 3 or fields[0] not in {'invalid', 'survive', 'burnout', 'any', 'policy'}:
            raise ValueError(f'{path}:{number}: expected outcome | arguments | description')
        if not fields[2]:
            raise ValueError(f'{path}:{number}: missing description')
        args = fields[1].split()
        if fields[0] != 'invalid' and (len(args) != 8 or
                any(not arg.isascii() or not arg.isdigit() for arg in args[:7]) or
                int(args[0]) < 1 or args[7] not in {'fifo', 'edf'}):
            raise ValueError(f'{path}:{number}: invalid simulation arguments')
        cases.append(fields)
    if not cases:
        raise ValueError('Case file contains no tests')
    return cases


def choose(screen, cases, initial_filter="", include_stress=False, initial_leaks=False):
    curses.curs_set(0)
    screen.keypad(True)
    selected = {i for i, case in enumerate(cases) if (include_stress or initial_filter or '[stress]' not in case[2])
                and initial_filter.lower() in ' '.join(case).lower()}
    cursor = 0
    repeats = 1
    leaks = initial_leaks
    query = initial_filter
    while True:
        visible = [i for i, case in enumerate(cases)
                   if query.lower() in ' '.join(case).lower()]
        cursor = min(cursor, max(0, len(visible) - 1))
        height, width = screen.getmaxyx()
        screen.erase()

        def put(row, value, attr=0):
            if 0 <= row < height and width > 1:
                try:
                    screen.addnstr(row, 0, value, width - 1, attr)
                except curses.error:
                    pass

        if height < 10 or width < 40:
            put(0, 'Resize to at least 40 x 10, or q to quit.')
            screen.refresh()
            if screen.getch() in (ord('q'), 27):
                return None
            continue

        put(0, ' CODEXION  /  TEST LAB', curses.A_BOLD)
        put(1, f' {len(selected)}/{len(cases)} selected  |  repeats: {repeats}  |  valgrind: {"on" if leaks else "off"}')
        put(2, ' Up/Down move  Space toggle  a all shown  n clear shown  / search')
        put(3, ' +/- repeats  l valgrind  Enter run  q quit  |  stress cases opt-in')
        put(4, f' Filter: {query or "(all)"}', curses.A_DIM)
        rows = max(1, height - 7)
        start = max(0, cursor - rows + 1)
        for row, position in enumerate(range(start, min(len(visible), start + rows)), 6):
            index = visible[position]
            outcome, args, desc = cases[index]
            mark = 'x' if index in selected else ' '
            put(row, f' [{mark}] {index + 1:02} {outcome:7} {desc}  |  {args}',
                curses.A_REVERSE if position == cursor else 0)
        put(height - 1, f' {len(visible)} shown | Results and log paths appear after execution', curses.A_DIM)
        screen.refresh()
        key = screen.getch()
        if key in (ord('q'), 27):
            return None
        if key in (curses.KEY_DOWN, ord('j')):
            cursor = min(cursor + 1, max(0, len(visible) - 1))
        elif key in (curses.KEY_UP, ord('k')):
            cursor = max(0, cursor - 1)
        elif key == curses.KEY_NPAGE:
            cursor = min(cursor + rows, max(0, len(visible) - 1))
        elif key == curses.KEY_PPAGE:
            cursor = max(0, cursor - rows)
        elif key == ord(' ') and visible:
            index = visible[cursor]
            selected.symmetric_difference_update({index})
        elif key == ord('a'):
            selected.update(visible)
        elif key == ord('n'):
            selected.difference_update(visible)
        elif key in (ord('+'), ord('=')):
            repeats = min(100, repeats + 1)
        elif key == ord('-'):
            repeats = max(1, repeats - 1)
        elif key == ord('l'):
            leaks = not leaks
        elif key == ord('/'):
            put(4, ' Search (empty clears): ' + ' ' * max(0, width - 25))
            curses.echo()
            curses.curs_set(1)
            try:
                query = screen.getstr(4, min(24, width - 2), max(1, width - 26)).decode(errors='replace')
            finally:
                curses.noecho()
                curses.curs_set(0)
            cursor = 0
        elif key in (10, 13, curses.KEY_ENTER) and selected:
            return sorted(selected), repeats, leaks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filter', default='')
    parser.add_argument('--stress', action='store_true')
    parser.add_argument('--leaks', action='store_true')
    options = parser.parse_args()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print('The menu needs a terminal; use run_tests.sh --batch.', file=sys.stderr)
        return 2
    try:
        cases = load_cases(Path(os.environ.get('CASES', HERE / 'cases.txt')))
        choice = curses.wrapper(choose, cases, options.filter, options.stress, options.leaks)
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError, curses.error) as error:
        print(f'Menu: {error}. Use --batch if this terminal is unsupported.', file=sys.stderr)
        return 2
    if choice is None:
        return 0
    indexes, repeats, leaks = choice
    failed = 0
    with tempfile.TemporaryDirectory(prefix='codexion-cases-') as temporary:
        selected = Path(temporary) / 'cases.txt'
        selected.write_text('\n'.join(' | '.join(cases[i]) for i in indexes) + '\n')
        env = dict(os.environ, CASES=str(selected))
        command = [str(HERE / 'run_tests.sh'), '--batch', '--stress']
        if leaks:
            command.append('--leaks')
        try:
            for iteration in range(1, repeats + 1):
                print(f'\nRun {iteration}/{repeats} — {len(indexes)} selected cases', flush=True)
                result = subprocess.run(command, env=env, check=False)
                if result.returncode in (130, 143) or result.returncode < 0:
                    print('Interrupted. Completed run logs are preserved.')
                    return 130
                if result.returncode == 2:
                    print('Runner setup failed; remaining repeats were skipped.')
                    return 2
                failed += result.returncode != 0
        except KeyboardInterrupt:
            print('\nInterrupted. Completed run logs are preserved.')
            return 130
    print(f'\nRuns: {repeats - failed} passed, {failed} failed')
    return int(failed > 0)


if __name__ == '__main__':
    sys.exit(main())
