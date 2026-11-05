#!/usr/bin/env python3
"""Run a command with stdout on a pseudo-terminal and record when each line arrives.

  stamp.py ARRIVALS -- COMMAND [ARGS...]
      Runs COMMAND with stdout attached to a pseudo-terminal, as in an
      interactive shell (stdio is then line-buffered). Output lines are copied
      to stdout without carriage returns; for every line, the arrival time in
      milliseconds since the command was started is written to ARRIVALS.
      Stdin and stderr are inherited. The exit status is the command's, or
      128 + signal number.

  stamp.py --analyze LOG ARRIVALS LIMIT_MS
      Compares each log line's printed timestamp with its arrival time and
      prints WARN lines when the burnout line, or output in general, reached
      the reader late. Details go to stdout as INFO lines.
"""
import os
import pty
import re
import subprocess
import sys
import time

LINE = re.compile(r'^(\d+) \d+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$')
# Output is considered buffered when lines arrive this much later than printed.
BUFFERED_MS = 100


def record(arrivals_path, command):
    master, slave = pty.openpty()
    start = time.monotonic()
    try:
        process = subprocess.Popen(command, stdout=slave, close_fds=True)
    except OSError as error:
        print(f'stamp.py: {error}', file=sys.stderr)
        return 127
    finally:
        os.close(slave)
    pending = b''
    with open(arrivals_path, 'w') as arrivals:
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:  # EIO: every writer closed the terminal
                chunk = b''
            if not chunk:
                break
            now = (time.monotonic() - start) * 1000
            pending += chunk.replace(b'\r', b'')
            *lines, pending = pending.split(b'\n')
            for line in lines:
                sys.stdout.buffer.write(line + b'\n')
                arrivals.write(f'{now:.3f}\n')
        if pending:
            sys.stdout.buffer.write(pending)
            arrivals.write(f'{(time.monotonic() - start) * 1000:.3f}\n')
    os.close(master)
    sys.stdout.flush()
    status = process.wait()
    return 128 - status if status < 0 else status


def analyze(log_path, arrivals_path, limit):
    with open(log_path, errors='replace') as log, open(arrivals_path) as arrivals:
        pairs = [(line.rstrip('\n'), float(stamp)) for line, stamp in zip(log, arrivals)]
    samples = []
    for line, arrived in pairs:
        match = LINE.match(line)
        if match:
            samples.append((line, arrived - int(match.group(1))))
    if not samples:
        print('INFO: no simulation lines to measure')
        return 0
    # Printed timestamps count from the simulation start, which is slightly
    # after the process start. Estimate that startup delay from the fastest
    # line, but never by more than 20 ms so fully buffered output still shows.
    startup = max(0.0, min(20.0, min(delay for _, delay in samples)))
    latencies = [(line, delay - startup) for line, delay in samples]
    worst_line, worst = max(latencies, key=lambda item: item[1])
    print(f'INFO: estimated startup {startup:.1f} ms; worst line latency {worst:.1f} ms: "{worst_line}"')
    for line, latency in latencies:
        if line.endswith('burned out'):
            print(f'INFO: burnout line arrived {latency:.1f} ms after its timestamp')
            if latency > limit:
                print(f'WARN: burnout line reached the terminal {latency:.0f} ms after its timestamp '
                      f'(limit {limit:g} ms): "{line}"')
    if worst > BUFFERED_MS:
        print(f'WARN: output reached the terminal up to {worst:.0f} ms late; is stdout buffered '
              f'or the print mutex held while sleeping?')
    return 0


def main(argv):
    if len(argv) == 5 and argv[1] == '--analyze':
        return analyze(argv[2], argv[3], float(argv[4]))
    if len(argv) >= 4 and argv[2] == '--':
        return record(argv[1], argv[3:])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
