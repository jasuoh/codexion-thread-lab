# Codexion test lab

Run `tests/run_tests.sh` in a terminal to open the interactive selector. It uses Python 3's standard-library `curses` module; no pip packages are needed. The runner uses Bash, awk and `timeout` (or `gtimeout` on macOS). Valgrind is optional.

```bash
tests/run_tests.sh                    # interactive menu in a terminal
tests/run_tests.sh --tui              # explicitly open the menu
tests/run_tests.sh --batch            # baseline cases, no interaction
tests/run_tests.sh --batch --stress   # include timing and scale experiments
tests/run_tests.sh invalid            # text filter, also works with fifo/edf
tests/run_tests.sh --batch -l         # memory checks for small cases
tests/run_tests.sh --batch -r         # data-race checks (Valgrind DRD) for small cases
tests/run_tests.sh --batch --repeat 20 edf  # repeat the selection 20 times
CODEXION=./my_build tests/run_tests.sh # select another executable
CODEXION_SRC=../project/coders CODEXION=../project/coders/codexion tests/run_tests.sh --batch
tests/check_build.sh ../project/coders # only the Makefile/Norm check
python3 tests/self_test.py            # test the checker without Codexion
python3 tests/check_functions.py coders/codexion  # forbidden functions in a binary
python3 tests/check_functions.py path/to/repo     # heuristic source scan, no build
```

The repository root has a Makefile with the same entry points: `make check`, `make stress`, `make leaks`, `make races`, `make repeat REPEAT=20`, `make full`, `make logs` and `make latest`; pass `CODEXION=…` and `CODEXION_SRC=…` on the command line.

Without arguments, redirected output uses batch mode. Unless `CODEXION` is set, the runner builds with `make -C coders` when that Makefile exists, and checks that project's Makefile. This checkout does not include a Codexion implementation: supply your binary before running simulation tests.

## Menu controls

| Key | Action |
|---|---|
| Up/Down or k/j | Move through cases |
| Page Up/Page Down | Move one page |
| Space | Toggle the current case |
| / | Search descriptions, arguments and outcomes; empty search clears the filter |
| a / n | Select / deselect every case currently shown |
| + / - | Set repeat count, from 1 to 100 |
| l | Toggle Valgrind checks |
| Enter | Run all selected cases, including selections hidden by the filter |
| q or Escape | Quit without running |

Baseline cases start selected; cases marked `[stress]` start deselected. Search `stress` to select those experiments. Search `invalid`, `burnout`, `survive`, `fifo` or `edf` to work on a particular group. Clear all selections before selecting only a filtered group if that is what you want to run.

Execution prints one result per case, reasons for failures, warnings, and a summary. Ctrl-C interrupts execution.

## Logs

Each batch gets its own directory, named after its start time: `tests/logs/run-20261104-191341-FDSx`. `tests/logs/latest` points to the newest one, and earlier runs are preserved. Every run directory contains:

| File | Contents |
|---|---|
| `run.info` | Start time, command line, binary path, modification time and SHA-256, git commit of the binary's and tester's checkouts (with an uncommitted-changes marker), settings, kernel, CPU count and load |
| `summary.txt` | The printed results without colors, plus the finish time |
| `functions.check`, `build.check` | Allowed-function and Makefile/Norm reports |
| `NN-expect.case` | Case definition, start time, exact command, result and its reasons |
| `NN-expect.out` / `.err` | stdout and stderr of the simulation |
| `NN-expect.check` / `.check.err` | Log checker output |
| `NN-expect.arrivals` / `.latency` | Arrival time of every stdout line and the latency analysis |
| `NN-expect.time` | Wall, user and system seconds |
| `NN-expect.vg` / `.race` | Optional memcheck and race-detector reports |

With `--repeat`, names get a repetition prefix (`r03-12-survive.out`). To trace a failure, compare `run.info` (which build, which machine load) with the case's `.case` and `.out` files; `make logs` lists every run with its result line.

To delete saved runs and Python caches, run `make clean` from the repository
root after tests finish. Use `make -n clean` to preview the command. Cleanup
only removes `tests/logs/` and `tests/__pycache__/`; custom `CODEXION_LOGDIR`
locations are managed separately. Run `make test` for the self-tests without
creating Python bytecode caches.

## Cases and expectations

`cases.txt` uses `expect | arguments | description`. Arguments are whitespace-separated tokens, not shell commands: quotes and shell expansions are not interpreted. Empty arguments are supported for testing no arguments.

| Outcome | Meaning |
|---|---|
| `invalid` | Reject input without simulation logs, crashes or hangs. Missing diagnostics and success exit status produce warnings because the subject does not prescribe them. |
| `survive` | No burnout; every coder must start at least the required number of compiles. See completion limits below. |
| `burnout` | A burnout must be logged with valid timing and no later state messages. |
| `any` | Either burnout or successful completion is accepted; log checks still apply. |
| `policy` | A boundary input may be rejected with a diagnostic and nonzero status, or produce a valid simulation. Zero required compiles may also exit successfully without output; log lines printed before an immediate stop produce a warning, a burnout fails. Inspect the warning against the implementation's documented policy. |

The 68 cases cover malformed input, negative values, single-coder shutdown, even and odd rings, both schedulers, cooldowns, zero-duration phases, repeated contention, burnout during different phases, scale, and tight boundaries. They are reasoned examples, not official evaluation cases. Generous baseline timings reduce timing sensitivity; they are still expectations to investigate, not proofs for every acquisition protocol. Tight feasible schedules are experiments because the acquisition policy and OS scheduling affect the outcome. Zero-duration phase and zero-required-count probes use `policy` because the subject does not precisely specify their validation. Ordinary baseline cases assume a zero dongle cooldown is supported. The suite does not impose an `INT_MAX` input limit: validate the range supported by your implementation without arithmetic overflow. Two `policy` probes pass values just above 32-bit `int` range; silent wraparound typically shows up as a premature burnout.

## Allowed functions and globals

Before the cases run, the runner inspects the binary with `nm` and fails when it imports a function outside the subject's allowed list (for example `pthread_detach`, `pthread_cond_signal`, `pthread_mutex_trylock`, `clock_gettime`, `nanosleep`, `calloc`, `strtol`, `fflush`) or defines a global variable. The report is saved as `functions.check` in the run directory. Some symbols are emitted by the compiler for allowed calls (`printf` can become `puts` or `__printf_chk`, `atoi` can become `strtol`); these are warnings, so check the source.

Given a directory, `check_functions.py` scans `.c`/`.h` sources instead, limited to `coders/` when present. That mode is a heuristic: it treats every called name that the project does not define as external, so macros or unusual formatting can produce false reports.

## Makefile and Norm

When the project directory is known (`CODEXION_SRC`, or `coders/` when `CODEXION` is not set), `check_build.sh` copies it to a temporary directory and checks: the `all`, `clean`, `fclean` and `re` rules, `NAME = codexion`, `-Wall -Wextra -Werror` and `-pthread` in the compiler commands, that a second `make` neither recompiles nor relinks, that `clean` removes object files and `fclean` the executable, and that `re` rebuilds. If `norminette` is installed, it must pass on every `.c` and `.h` file. The project's own directory is never modified. Use `--no-build-check` to skip it.

## Data races

`--races` runs each non-invalid simulation with at most `RACE_MAX_CODERS` coders (default 8) under Valgrind DRD; any reported conflict fails the case and is saved as `.race`. DRD only sees interleavings that actually occur under its serialized scheduling, so a clean report is evidence, not proof, and very short unprotected windows can be missed. `RACE_TOOL=helgrind` is available, but recent glibc versions make Helgrind report "dubious" condition-variable broadcasts from inside `pthread_cond_timedwait` even in correct programs. Compiling with `-g` gives source lines in the reports.

## What the checker can establish

- Log format, coder IDs, nondecreasing timestamps and per-coder action order.
- Minimum visible phase durations; excessive phase duration produces a warning.
- Impossible overlap between neighbouring compiles.
- Cooldown violations when a compile starts before the earliest possible previous release plus cooldown.
- Premature or late burnout, late compile starts, and output after burnout. A coder **can burn out while compiling** if its deadline expires during that phase.
- Compile starts long after every coder completed the required compiles (warning: the simulation should already have stopped).
- Missing compile starts on successful termination, crashes, execution failures, and hangs. A normal nonzero simulation exit status is a warning because the subject does not specify exit codes.

Timing checks assume log timestamps represent the corresponding phase transitions closely. Delayed logging can distort measured durations; a failure is evidence to investigate against an instrumented trace. The log does not identify individual dongles or exact release times. The checker uses `compile_start + time_to_compile` as the earliest possible release, not the debugging log timestamp: logging may be delayed after release. This avoids a false failure but cannot catch all late-release cooldown violations or misuse while taking dongles.

Final compile completion can be invisible when shutdown suppresses subsequent logs. The checker warns when it cannot infer completion from later timestamps; it cannot prove that the binary waited for the final phase to finish. Start counts are not completion counts.

The runner also measures the CPU time of each simulation. Runs of at least 0.5 s that use more CPU time than `CPU_WARN` percent of the wall time (by default, more than one fully busy core on average) produce a busy-waiting warning. Raise the threshold or set `CPU_WARN=0` if many threads or zero-duration phases legitimately keep the CPU busy.

The simulation runs with stdout on a pseudo-terminal, as in an interactive shell, and the arrival time of every line is recorded. When the burnout line reaches the terminal more than `LATENCY_WARN` ms (default 10) after its printed timestamp, or any output arrives more than 100 ms late (full buffering, or a print mutex held while sleeping), the case gets a warning. The comparison assumes the simulation clock starts close to process start; the estimated startup delay is subtracted, at most 20 ms.

Request arrival times are also absent, so FIFO/EDF arbitration cannot be verified from these logs. Use instrumented traces and design review for scheduling, and Helgrind/DRD/ThreadSanitizer for races. Memory checks are separate Valgrind executions; their timing and survival outcomes are not graded because instrumentation changes timing. Leaks, memory errors, crashes, or failure to finish the memory check fail the case. Increase `TIME_LIMIT` if instrumentation needs more time.

## Timing and runner settings

| Environment variable | Default | Purpose |
|---|---|---|
| `CODEXION` | `coders/codexion` | Executable to test |
| `CASES` | `tests/cases.txt` | Alternate case list |
| `CODEXION_LOGDIR` | `tests/logs` | Parent directory for preserved run logs |
| `TIME_LIMIT` | 20 seconds | Positive integer per-run timeout; memory runs allow five times this |
| `SLACK` | 2 ms | Additional deadline tolerance |
| `PHASE_TOL` | 10 ms | Phase overrun warning threshold |
| `CPU_WARN` | 100 % | Busy-waiting warning threshold, CPU time as a share of wall time; 0 disables |
| `LATENCY_WARN` | 10 ms | Burnout output latency warning threshold; 0 disables |
| `REPEAT` | 1 | Repetitions, 1 to 100 (same as `--repeat`) |
| `RACE_TOOL` | `drd` | Race detector for `--races`: `drd` or `helgrind` |
| `RACE_MAX_CODERS` | 8 | Largest coder count run under the race detector; race runs allow ten times `TIME_LIMIT` |
| `CODEXION_SRC` | `coders/` without `CODEXION` | Project directory for the Makefile/Norm check |

The checker reads timestamps after the process exits; it cannot establish when a reader actually received buffered output. The subject's burnout reporting allowance is 10 ms; `SLACK` is an extra checker tolerance, not a subject requirement. Minimum phase and premature burnout checks allow 1 ms for timestamp rounding. Successful runs and clean detector reports provide evidence, not proof. Investigate failures with saved logs and repeat under ordinary machine load.

`self_test.py` exercises the checker with known valid and invalid synthetic traces and checks runner timeouts, exit handling, case validation, boundary policies, memory-check failures, and menu selection using controlled fixtures. It also validates all case definitions. It does not test a Codexion implementation.

Malformed case files and invalid runner settings are rejected before execution. A case file need not end with a newline. Exit status is 0 when no cases fail (warnings may remain), 1 for test failures, 2 for setup/input errors, and 130 for interruption. Inspect warnings: an accepted policy probe or an unobservable final completion is not proof of correctness.
