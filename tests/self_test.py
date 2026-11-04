#!/usr/bin/env python3
"""Regression checks for the checker, using synthetic logs and fake binaries."""
from pathlib import Path
import os
import shutil
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

    def completion_log(self, restart):
        log = '0 1 has taken a dongle\n0 1 has taken a dongle\n0 1 is compiling\n20 1 is debugging\n'
        log += '20 2 has taken a dongle\n20 2 has taken a dongle\n20 2 is compiling\n30 1 is refactoring\n'
        log += f'40 2 is debugging\n{restart} 1 has taken a dongle\n{restart} 1 has taken a dongle\n'
        return log + f'{restart} 1 is compiling\n'

    def test_compile_after_completion_warns(self):
        output = self.check_log(self.completion_log(300), True, expect='survive')
        self.assertIn('should have stopped', output)

    def test_compile_within_completion_tolerance(self):
        output = self.check_log(self.completion_log(45), True, expect='survive')
        self.assertNotIn('should have stopped', output)

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
    def run_case(self, body, case, options=(), settings=None, helpers=None, inspect=None):
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
            result = subprocess.run([str(HERE / 'run_tests.sh'), '--batch', *options],
                                    env=env, text=True, capture_output=True, timeout=12)
            if inspect:
                inspect(folder / 'logs')
            return result

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

    def test_zero_count_output_before_stop_is_warning(self):
        result = self.run_case('echo "0 1 has taken a dongle"; echo "0 1 has taken a dongle"; echo "0 1 is compiling"',
                               'policy | 2 1000 20 10 10 0 0 fifo | zero count')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('WARN: zero required compiles still produced', result.stdout)

    def test_busy_cpu_is_warning(self):
        spin = ('exec python3 -c "import time\ne = time.time() + 0.8\nwhile time.time() < e: pass\n'
                'print(\\"800 1 burned out\\")"')
        case = 'burnout | 1 800 20 10 10 1 0 fifo | spins'
        result = self.run_case(spin, case, settings={'TIME_LIMIT': '4', 'CPU_WARN': '50'})
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('busy-waiting', result.stdout)
        result = self.run_case(spin, case, settings={'TIME_LIMIT': '4', 'CPU_WARN': '0'})
        self.assertNotIn('busy-waiting', result.stdout)

    def test_idle_run_has_no_cpu_warning(self):
        result = self.run_case('sleep 0.6; echo "600 1 burned out"', 'burnout | 1 600 20 10 10 1 0 fifo | sleeps')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('busy-waiting', result.stdout)

    def test_log_directory_is_traceable(self):
        def inspect(logs):
            runs = sorted(logs.glob('run-*'))
            self.assertEqual(len(runs), 1)
            self.assertRegex(runs[0].name, r'^run-\d{8}-\d{6}-\w{4}$')
            self.assertEqual((logs / 'latest').resolve(), runs[0].resolve())
            info = (runs[0] / 'run.info').read_text()
            for field in ('started:', 'binary:', 'sha256:', 'settings:', 'machine:'):
                self.assertIn(field, info)
            names = sorted(p.name for p in runs[0].glob('*.case'))
            self.assertEqual(names, ['r01-01-invalid.case', 'r02-01-invalid.case'])
            self.assertIn('result: OK', (runs[0] / 'r02-01-invalid.case').read_text())
            summary = (runs[0] / 'summary.txt').read_text()
            self.assertIn('repetition 2/2', summary)
            self.assertIn('passed: 2', summary)
        result = self.run_case('echo error >&2; exit 1', 'invalid | | no args',
                               options=['--repeat', '2'], inspect=inspect)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bad_repeat_rejected(self):
        for value in ('0', '101', 'x'):
            with self.subTest(value=value):
                result = self.run_case('exit 1', 'invalid | | no args', options=['--repeat', value])
                self.assertEqual(result.returncode, 2)

    def test_late_burnout_output_warns(self):
        body = 'sleep 0.3; echo "100 1 burned out"'
        result = self.run_case(body, 'burnout | 1 100 20 10 10 1 0 fifo | late print')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('reached the terminal', result.stdout)
        result = self.run_case(body, 'burnout | 1 100 20 10 10 1 0 fifo | late print',
                               settings={'LATENCY_WARN': '0'})
        self.assertNotIn('reached the terminal', result.stdout)

    def test_output_runs_on_a_terminal(self):
        result = self.run_case('[ -t 1 ] && echo "100 1 burned out"',
                               'burnout | 1 100 20 10 10 1 0 fifo | tty')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_race_report_is_failure(self):
        result = self.run_case('echo "100 1 burned out"', 'burnout | 1 100 20 10 10 1 0 fifo | race',
                               options=['--races'], helpers={'valgrind': 'exit 43'})
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('reported data races', result.stdout)

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


class FunctionCheckTests(unittest.TestCase):
    def scan(self, source):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'main.c').write_text(source)
            return subprocess.run(['python3', str(HERE / 'check_functions.py'), folder],
                                  capture_output=True, text=True)

    def test_allowed_source(self):
        result = self.scan('#include <stdio.h>\nstatic int\thelper(int x)\n{\n\treturn ((int)(x));\n}\n\n'
                           'int\tmain(void)\n{\n\tprintf("%d\\n", helper(1)); /* sleep(1) */\n'
                           '\treturn (0);\n}\n')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_forbidden_source(self):
        for call in ['pthread_detach(t)', 'pthread_cond_signal(&c)', 'clock_gettime(0, &ts)',
                     'pthread_mutex_trylock(&m)', 'nanosleep(&ts, 0)']:
            with self.subTest(call=call):
                result = self.scan(f'int\tmain(void)\n{{\n\t{call};\n\treturn (0);\n}}\n')
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(call.split('(')[0], result.stdout)

    def test_global_variable(self):
        result = self.scan('int\tg_count = 0;\n\nint\tmain(void)\n{\n\treturn (g_count);\n}\n')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('global variable', result.stdout)

    @unittest.skipUnless(shutil.which('cc') and shutil.which('nm'), 'needs cc and nm')
    def test_binary_imports(self):
        with tempfile.TemporaryDirectory() as folder:
            source, binary = Path(folder) / 'a.c', Path(folder) / 'a.out'
            source.write_text('#include <stdlib.h>\n#include <time.h>\nint main(void)\n{\n'
                              '\tstruct timespec ts;\n\tvoid *p = malloc(1);\n\tfree(p);\n'
                              '\treturn clock_gettime(CLOCK_MONOTONIC, &ts);\n}\n')
            subprocess.run(['cc', str(source), '-o', str(binary)], check=True)
            result = subprocess.run(['python3', str(HERE / 'check_functions.py'), str(binary)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn('clock_gettime', result.stdout)
            self.assertNotIn('malloc', result.stdout)


class BuildCheckTests(unittest.TestCase):
    GOOD = ('NAME = codexion\nCFLAGS = -Wall -Wextra -Werror -pthread\nOBJS = main.o\n\n'
            'all: $(NAME)\n\n$(NAME): $(OBJS)\n\tcc $(CFLAGS) $(OBJS) -o $(NAME)\n\n'
            '%.o: %.c\n\tcc $(CFLAGS) -c $< -o $@\n\nclean:\n\trm -f $(OBJS)\n\n'
            'fclean: clean\n\trm -f $(NAME)\n\nre: fclean all\n\n.PHONY: all clean fclean re\n')

    def check(self, makefile):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'Makefile').write_text(makefile)
            (Path(folder) / 'main.c').write_text('int\tmain(void)\n{\n\treturn (0);\n}\n')
            return subprocess.run([str(HERE / 'check_build.sh'), folder], capture_output=True, text=True)

    @unittest.skipUnless(shutil.which('cc') and shutil.which('make'), 'needs cc and make')
    def test_good_makefile(self):
        result = self.check(self.GOOD)
        self.assertEqual(result.returncode, 0, result.stdout)

    @unittest.skipUnless(shutil.which('cc') and shutil.which('make'), 'needs cc and make')
    def test_relink_and_missing_flags(self):
        result = self.check('all:\n\tcc -Wall main.c -o codexion\nclean:\nfclean:\n\trm -f codexion\n'
                            're: fclean all\n')
        self.assertEqual(result.returncode, 1, result.stdout)
        for message in ('-Wextra', '-Werror', 'relinks'):
            self.assertIn(message, result.stdout)


class LatencyTests(unittest.TestCase):
    def analyze(self, lines):
        with tempfile.TemporaryDirectory() as folder:
            log, arrivals = Path(folder) / 'out', Path(folder) / 'arrivals'
            log.write_text(''.join(line + '\n' for line, _ in lines))
            arrivals.write_text(''.join(f'{at}\n' for _, at in lines))
            return subprocess.run(['python3', str(HERE / 'stamp.py'), '--analyze', str(log),
                                   str(arrivals), '10'], capture_output=True, text=True).stdout

    def test_prompt_output(self):
        output = self.analyze([('0 1 has taken a dongle', 2.0), ('800 1 burned out', 803.0)])
        self.assertNotIn('WARN', output)

    def test_buffered_output(self):
        output = self.analyze([('0 1 has taken a dongle', 801.0), ('800 1 burned out', 801.5)])
        self.assertIn('buffered', output)

    def test_late_burnout(self):
        output = self.analyze([('0 1 has taken a dongle', 1.0), ('800 1 burned out', 830.0)])
        self.assertIn('burnout line reached the terminal', output)


class MenuTests(unittest.TestCase):
    def test_all_case_definitions(self):
        cases = menu.load_cases(HERE / 'cases.txt')
        self.assertEqual(len(cases), 68)
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
