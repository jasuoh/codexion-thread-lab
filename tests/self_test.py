#!/usr/bin/env python3
"""Regression checks for the checker, using synthetic logs and fake binaries."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import menu

HERE = Path(__file__).resolve().parent


class CheckerTests(unittest.TestCase):
    def check_log(self, log, passes, **options):
        config = dict(n=2, ttb=1000, ttc=20, ttd=10, ttr=10, req=1, cd=0, expect='any')
        config.update(options)
        command = ['awk']
        for key, value in config.items():
            command.extend(['-v', f'{key}={value}'])
        result = subprocess.run(command + ['-f', str(HERE / 'check_log.awk')],
                                input=log, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if passes else 1, result.stdout + result.stderr)
        return result.stdout

    def test_single_coder_burnout(self):
        self.check_log('0 1 has taken a dongle\n100 1 burned out\n', True, n=1, ttb=100, expect='burnout')

    def test_burnout_during_compile(self):
        self.check_log('0 1 has taken a dongle\n0 1 has taken a dongle\n0 1 is compiling\n50 1 burned out\n',
                       True, ttb=50, ttc=100, expect='burnout')

    def test_premature_burnout(self):
        self.check_log('20 1 burned out\n', False, ttb=100, expect='burnout')

    def test_late_burnout(self):
        self.check_log('120 1 burned out\n', False, ttb=100, expect='burnout')

    def test_output_after_burnout(self):
        self.check_log('100 1 burned out\n100 2 has taken a dongle\n', False, ttb=100)

    def test_overlapping_compiles(self):
        log = ''.join(f'{t} {x} {action}\n' for t, x in [(0, 1), (5, 2)]
                      for action in ['has taken a dongle', 'has taken a dongle', 'is compiling'])
        self.check_log(log, False)

    def test_cooldown(self):
        log = '0 1 has taken a dongle\n0 1 has taken a dongle\n0 1 is compiling\n20 1 is debugging\n'
        log += '25 2 has taken a dongle\n25 2 has taken a dongle\n25 2 is compiling\n'
        self.check_log(log, False, cd=20)

    def test_delayed_debug_log_is_not_release_time(self):
        log = '0 1 has taken a dongle\n0 1 has taken a dongle\n0 1 is compiling\n'
        log += '40 2 has taken a dongle\n40 2 has taken a dongle\n40 2 is compiling\n45 1 is debugging\n60 2 is debugging\n'
        self.check_log(log, True, cd=20, expect='survive')

    def test_incomplete_any_log(self):
        self.check_log('0 1 has taken a dongle\n', False)

    def test_completion_not_observable(self):
        log = '0 1 has taken a dongle\n0 1 has taken a dongle\n0 1 is compiling\n20 1 is debugging\n'
        log += '20 2 has taken a dongle\n20 2 has taken a dongle\n20 2 is compiling\n'
        self.assertIn('not visible', self.check_log(log, True, expect='survive'))

    def test_format_and_ids(self):
        for log in ['hello\n', '0 3 has taken a dongle\n', '']:
            with self.subTest(log=log):
                self.check_log(log, False)

    def test_runner_rejection_and_no_match(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            binary = folder / 'fake'
            binary.write_text('#!/bin/sh\necho "invalid input" >&2\nexit 1\n')
            binary.chmod(0o755)
            cases = folder / 'cases'
            cases.write_text('invalid | | no arguments\ninvalid | -1 | negative\n')
            env = dict(os.environ, CODEXION=str(binary), CASES=str(cases),
                       CODEXION_LOGDIR=str(folder / 'logs'))
            result = subprocess.run([str(HERE / 'run_tests.sh'), '--batch'], env=env,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('passed:', result.stdout)
            result = subprocess.run([str(HERE / 'run_tests.sh'), '--batch', 'does-not-exist'],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)


class RunnerTests(unittest.TestCase):
    def run_case(self, body, case, options=(), settings=None, helpers=None):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            binary = folder / 'fake'
            binary.write_text('#!/bin/sh\n' + body + '\n')
            binary.chmod(0o755)
            cases = folder / 'cases'
            cases.write_text(case)
            env = dict(os.environ, CODEXION=str(binary), CASES=str(cases),
                       CODEXION_LOGDIR=str(folder / 'logs'), TIME_LIMIT='1')
            env.update(settings or {})
            for name, content in (helpers or {}).items():
                helper = folder / name
                helper.write_text('#!/bin/sh\n' + content + '\n')
                helper.chmod(0o755)
            if helpers:
                env['PATH'] = str(folder) + os.pathsep + env['PATH']
            return subprocess.run([str(HERE / 'run_tests.sh'), '--batch', *options],
                                  env=env, text=True, capture_output=True, timeout=8)

    def test_final_row_without_newline(self):
        result = self.run_case('echo error >&2; exit 1', 'invalid | | no args')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_malformed_case_rejected_before_execution(self):
        for row in ['survive | 2 100 | incomplete', 'survive | abc 100 10 10 10 1 0 fifo | bad',
                    'invalid | |', 'typo | | description', 'invalid | | desc | extra']:
            with self.subTest(row=row):
                result = self.run_case('echo SHOULD_NOT_RUN', row)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertNotIn('SHOULD_NOT_RUN', result.stdout)

    def test_zero_timeout_rejected(self):
        result = self.run_case('exit 0', 'invalid | | no args', settings={'TIME_LIMIT': '0'})
        self.assertEqual(result.returncode, 2)

    def test_execution_failure_does_not_pass_invalid_case(self):
        for code in (125, 126, 127):
            with self.subTest(code=code):
                result = self.run_case(f'exit {code}', 'invalid | | no args')
                self.assertEqual(result.returncode, 1, result.stdout)

    def test_timeout(self):
        result = self.run_case('exec sleep 5', 'invalid | | hangs')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('did not terminate', result.stdout)

    def test_crash(self):
        result = self.run_case('kill -TERM $$', 'invalid | | crashes')
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_invalid_simulation_on_stderr(self):
        result = self.run_case('echo "0 1 has taken a dongle" >&2; exit 1', 'invalid | | invalid')
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_valid_burnout_nonzero_status_is_warning(self):
        result = self.run_case('echo "100 1 burned out"; exit 1',
                               'burnout | 1 100 20 10 10 1 0 fifo | burnout')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('WARN: simulation exited', result.stdout)

    def test_boundary_rejection_or_zero_count_success(self):
        for body, row in [('echo unsupported >&2; exit 1',
                          'policy | 2 1000 0 10 10 1 0 fifo | zero duration'),
                         ('exit 0', 'policy | 2 1000 20 10 10 0 0 fifo | zero count')]:
            with self.subTest(row=row):
                result = self.run_case(body, row)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn('WARN:', result.stdout)

    def test_policy_does_not_accept_silent_incomplete_run(self):
        result = self.run_case('exit 0', 'policy | 2 1000 0 10 10 1 0 fifo | zero duration')
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_zero_count_does_not_accept_burnout(self):
        result = self.run_case('echo "100 1 burned out"',
                               'policy | 2 100 20 10 10 0 0 fifo | zero count')
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_valgrind_crash_is_failure(self):
        result = self.run_case('echo error >&2; exit 1', 'invalid | | invalid',
                               options=['--leaks'], helpers={'valgrind': 'exit 139'})
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('Valgrind check incomplete', result.stdout)

    def test_stress_selection(self):
        cases = 'invalid | | baseline\ninvalid | -1 | [stress] experiment\n'
        result = self.run_case('echo error >&2; exit 1', cases)
        self.assertIn('passed: 1', result.stdout)
        result = self.run_case('echo error >&2; exit 1', cases, options=['--stress'])
        self.assertIn('passed: 2', result.stdout)


class MenuTests(unittest.TestCase):
    def test_all_case_definitions(self):
        cases = menu.load_cases(HERE / 'cases.txt')
        self.assertEqual(len(cases), 63)
        self.assertTrue(any(case[0] == 'policy' for case in cases))

    def test_bad_case_definition(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'cases'
            path.write_text('survive | 2 | incomplete')
            with self.assertRaises(ValueError):
                menu.load_cases(path)

    def test_selection_repeat_and_leaks(self):
        screen = mock.Mock()
        screen.getmaxyx.return_value = (24, 80)
        screen.getch.side_effect = [ord('n'), ord(' '), ord('+'), ord('l'), 10]
        cases = [['invalid', '', 'no args'], ['burnout', '1 100 1 1 1 1 0 fifo', 'one coder']]
        with mock.patch.object(menu.curses, 'curs_set'):
            self.assertEqual(menu.choose(screen, cases), ([0], 2, True))

    def test_filter_initial_selection(self):
        screen = mock.Mock()
        screen.getmaxyx.return_value = (24, 80)
        screen.getch.return_value = 10
        cases = [['invalid', '', 'no args'], ['burnout', '1 100 1 1 1 1 0 edf', '[stress] one coder']]
        with mock.patch.object(menu.curses, 'curs_set'):
            self.assertEqual(menu.choose(screen, cases, 'edf'), ([1], 1, False))

    def test_small_terminal_can_quit(self):
        screen = mock.Mock()
        screen.getmaxyx.return_value = (4, 20)
        screen.getch.return_value = ord('q')
        with mock.patch.object(menu.curses, 'curs_set'):
            self.assertIsNone(menu.choose(screen, [['invalid', '', 'no args']]))


if __name__ == '__main__':
    unittest.main()
