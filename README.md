# Codexion — pthread Learning Guide & Test Lab

Learning resources and a test harness for the 42 **Codexion** concurrency
project. Explore POSIX threads, mutexes, condition variables, timing, and
FIFO/EDF scheduling, then test your own implementation.

This repository contains a guide and testing tools. A Codexion implementation
is not included.

## What's included

- [Learning guide](GUIDE.md): explanations, examples, and design considerations.
- [PDF guide](GUIDE.pdf): a downloadable version for offline reading.
- [Test lab](tests/README.md): an interactive terminal selector, 68 test cases,
  a log checker, forbidden-function, Makefile and Norm checks, busy-waiting
  and output-latency detection, optional Valgrind memory and race checks, and
  timestamped, traceable logs.
- Self-tests for the test tools, using synthetic traces and controlled fixtures.

## Getting started

Clone the repository and enter its directory:

```bash
git clone https://github.com/jasuoh/pthread-multithreading-codexion.git
cd pthread-multithreading-codexion
```

The tools use Bash, awk, Python 3, and `timeout` (`gtimeout` on macOS).
The interactive menu also needs Python's `curses` module. Make is used for the
convenience commands below; Valgrind is optional for memory checks.
No pip packages are required.

Check the test tools without a Codexion binary:

```bash
make test
```

To test your implementation, point the lab at your executable and, for the
Makefile and Norm check, at its project directory:

```bash
make check  CODEXION=/path/to/coders/codexion CODEXION_SRC=/path/to/coders
make stress CODEXION=/path/to/coders/codexion
make leaks  CODEXION=/path/to/coders/codexion
make races  CODEXION=/path/to/coders/codexion
make repeat CODEXION=/path/to/coders/codexion REPEAT=20
make tui    CODEXION=/path/to/coders/codexion
```

`make` alone lists every target. The same runs are available directly, for
example `CODEXION=/path/to/codexion tests/run_tests.sh --batch --races`.
Without `CODEXION`, the runner looks for `coders/codexion`, runs
`make -C coders` if a Makefile exists there, and checks that Makefile.
In the menu, use arrow keys to navigate, Space to toggle cases, Enter to run,
and `q` to quit. See the [test lab documentation](tests/README.md) for filters,
settings, and how to interpret results.

## Results and cleanup

Each batch saves its results in a directory named after its start time, such
as `tests/logs/run-20261104-191341-FDSx`; `tests/logs/latest` points to the
newest. `run.info` records the binary's checksum and git commit, the settings
and the machine load, so a failure can be traced back to the exact build.
`make logs` lists all runs and `make latest` shows the newest summary.
Review failures and warnings there before cleaning up:

```bash
make -n clean # preview cleanup
make clean    # delete saved test logs and Python caches
```

Cleanup removes `tests/logs/` and `tests/__pycache__/`. Custom log locations
set through `CODEXION_LOGDIR` must be managed separately.

## Learning and test limitations

These are independent learning resources, not official 42 evaluation tools.
Use your current assignment subject as the source of truth; the subject PDF
is not distributed in this repository. The guide references subject v1.1 and
was written with AI assistance, so check its explanations against your subject,
man pages, and your own experiments.

The checker can flag log-format problems, timing violations, impossible
neighbouring compiles, and incomplete runs. Logs alone cannot prove race
freedom, FIFO/EDF arbitration, or completion of the final compile. Timing
results also depend on the machine and scheduling conditions. See the
[test lab limitations](tests/README.md#what-the-checker-can-establish) before
interpreting a passing run as evidence of correctness.

## License

Original code and documentation are available under the [MIT License](LICENSE).
References and quotations from the 42 subject remain the property of their
respective rights holders and are not relicensed by this repository.
