#!/usr/bin/env python3
"""Report functions and global variables that the Codexion subject does not allow.

Usage:
  check_functions.py BINARY          inspect imported symbols with nm (accurate)
  check_functions.py SOURCE_DIR      scan .c/.h files (heuristic, no build needed);
                                     only SOURCE_DIR/coders is scanned when it exists

Exit status: 0 nothing found, 1 disallowed use found, 2 usage or tool error.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys

# Allowed external functions, from the subject (see GUIDE.md section 3).
ALLOWED = {
    'pthread_create', 'pthread_join',
    'pthread_mutex_init', 'pthread_mutex_lock', 'pthread_mutex_unlock', 'pthread_mutex_destroy',
    'pthread_cond_init', 'pthread_cond_wait', 'pthread_cond_timedwait',
    'pthread_cond_broadcast', 'pthread_cond_destroy',
    'gettimeofday', 'usleep', 'write', 'malloc', 'free', 'printf', 'fprintf',
    'strcmp', 'strlen', 'atoi', 'memset',
}

# Symbols a compiler may emit for allowed calls (printf("x\n") -> puts, ...).
# They are reported as notes because the source may still be compliant.
COMPILER_SUBSTITUTES = {
    'puts': 'printf', 'putchar': 'printf', 'fputs': 'fprintf', 'fputc': 'fprintf',
    'fwrite': 'fprintf', 'memcpy': 'struct copy', 'memmove': 'struct copy',
    '__printf_chk': 'printf', '__fprintf_chk': 'fprintf', '__memset_chk': 'memset',
    '__memcpy_chk': 'struct copy', 'strtol': 'atoi', '__isoc23_strtol': 'atoi',
}

# Runtime and toolchain symbols that appear in every executable.
RUNTIME = re.compile(r'^(__libc_start_main|__libc_csu_\w+|__cxa_finalize|__cxa_atexit|'
                     r'__gmon_start__|_ITM_\w+|__stack_chk_fail|__stack_chk_guard|'
                     r'_Jv_RegisterClasses|__deregister_frame_info|__register_frame_info|'
                     r'__errno_location|__error|dyld_stub_binder|__tls_get_addr|'
                     r'__(a|t|ub|l|m)san_\w+|__sanitizer_\w+|__asan\w*|__tsan\w*|__ubsan\w*|'
                     r'_?stdout|_?stderr|__stdoutp|__stderrp|_GLOBAL_OFFSET_TABLE_)$')

# Common mistakes worth naming explicitly in the source scan.
KNOWN_FORBIDDEN = {
    'pthread_detach', 'pthread_cond_signal', 'pthread_mutex_trylock', 'pthread_condattr_setclock',
    'clock_gettime', 'nanosleep', 'sleep', 'strtol', 'strtoll', 'strtoul', 'sscanf', 'puts',
    'exit', 'calloc', 'realloc', 'strdup', 'strncmp', 'memcpy', 'sem_init', 'sem_open', 'sem_wait',
    'sem_post', 'fork', 'signal', 'perror', 'strerror', 'time', 'clock', 'abort', 'fflush',
}

KEYWORDS = {'if', 'while', 'for', 'switch', 'return', 'sizeof', 'else', 'do', 'case',
            'defined', '_Static_assert', 'typeof', '__attribute__', 'va_start', 'va_end', 'va_arg',
            # type names inside casts such as (int)(value)
            'void', 'char', 'short', 'int', 'long', 'float', 'double', 'signed', 'unsigned',
            'const', 'volatile', 'struct', 'union', 'enum', 'bool', '_Bool', 'size_t', 'ssize_t',
            'time_t', 'suseconds_t', 'uint64_t', 'int64_t', 'uint32_t', 'int32_t', 'useconds_t'}


def strip_code(text):
    """Remove comments, string and character literals, keeping line structure."""
    pattern = re.compile(r'//[^\n]*|/\*.*?\*/|"(\\.|[^"\\\n])*"|\'(\\.|[^\'\\\n])*\'', re.S)
    return pattern.sub(lambda m: re.sub(r'[^\n]', ' ', m.group(0)), text)


def check_binary(path):
    nm = shutil.which('nm')
    if not nm:
        print('ERROR: nm is required to inspect a binary', file=sys.stderr)
        return 2
    imported = subprocess.run([nm, '-u', str(path)], capture_output=True, text=True)
    defined = subprocess.run([nm, str(path)], capture_output=True, text=True)
    if imported.returncode or defined.returncode:
        print('ERROR: nm failed: ' + (imported.stderr or defined.stderr).strip(), file=sys.stderr)
        return 2
    bad, notes = [], []
    for line in imported.stdout.splitlines():
        if not line.strip():
            continue
        name = line.split()[-1].split('@')[0]
        if name.startswith('_') and name[1:] in ALLOWED | set(COMPILER_SUBSTITUTES):
            name = name[1:]  # macOS prefixes C symbols with an underscore
        if name in ALLOWED or RUNTIME.match(name):
            continue
        if name in COMPILER_SUBSTITUTES:
            notes.append(f'{name} (often emitted by the compiler for {COMPILER_SUBSTITUTES[name]}; '
                         f'check the source)')
        else:
            bad.append(name)
    globals_found = []
    for line in defined.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1] in 'BDC' and '@' not in parts[2] and not \
                re.match(r'^_*(edata|end|bss_start|data_start|dso_handle|TMC_END__|IO_stdin_used|'
                         r'stdout|stderr|environ)\w*$', parts[2]):
            globals_found.append(parts[2])
    return report(sorted(set(bad)), sorted(set(notes)), sorted(set(globals_found)))


def check_sources(folder):
    # The subject's submission lives in coders/; ignore test helpers elsewhere.
    if (folder / 'coders').is_dir():
        folder = folder / 'coders'
    files = [p for p in folder.rglob('*') if p.suffix in ('.c', '.h') and p.is_file()]
    if not files:
        print(f'ERROR: no .c or .h files under {folder}', file=sys.stderr)
        return 2
    texts = {p: strip_code(p.read_text(errors='replace')) for p in files}
    own = set()
    for text in texts.values():
        own.update(re.findall(r'^\s*#\s*define\s+(\w+)', text, re.M))
        # Norm-style definitions and prototypes start at column 0: "type\tname(".
        own.update(re.findall(r'^(?!return\b)[A-Za-z_][\w \t\*]*?[\s\*](\w+)\s*\(', text, re.M))
        own.update(re.findall(r'\(\s*\*\s*(\w+)\s*\)\s*\(', text))  # function pointers
        own.update(re.findall(r'typedef\b[^;]*?\b(\w+)\s*;', text))
    bad = {}
    for path, text in texts.items():
        if path.suffix != '.c':
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith('#'):
                continue
            for name in re.findall(r'(?<![\w.>])(\w+)\s*\(', line):
                if name in ALLOWED or name in KEYWORDS or name.isupper():
                    continue
                if name in own and name not in KNOWN_FORBIDDEN:
                    continue
                bad.setdefault(name, f'{path.relative_to(folder)}:{number}')
    globals_found = []
    for path, text in texts.items():
        if path.suffix != '.c':
            continue
        for number, line in enumerate(text.splitlines(), 1):
            # A file-scope variable: column 0, ends in ';', no '(' and not a typedef/extern.
            if re.match(r'^(?!typedef|extern|struct\s+\w+\s*;|enum\b|#)(static\s+)?[A-Za-z_][\w \t\*\[\]]*'
                        r'(=[^;(]*)?;\s*$', line) and '(' not in line:
                globals_found.append(f'{line.strip()} ({path.relative_to(folder)}:{number})')
    listed = [f'{name} (first use {where})' for name, where in sorted(bad.items())]
    return report(listed, [], globals_found)


def report(bad, notes, globals_found):
    for name in bad:
        print(f'FAIL: function not allowed by the subject: {name}')
    for name in globals_found:
        print(f'FAIL: global variable: {name}')
    for note in notes:
        print(f'WARN: {note}')
    if not bad and not globals_found:
        print('OK: only allowed functions are used')
    return 1 if bad or globals_found else 0


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    target = Path(argv[1])
    if target.is_dir():
        return check_sources(target)
    if target.is_file():
        return check_binary(target)
    print(f'ERROR: not found: {target}', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
