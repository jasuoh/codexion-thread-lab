# Codexion test lab

Run `tests/run_tests.sh` in a terminal to open the interactive selector. It uses Python 3's standard-library `curses` module; no pip packages are needed. The runner uses Bash, awk and `timeout` (or `gtimeout` on macOS). Valgrind is optional.

```bash
tests/run_tests.sh                    # interactive menu in a terminal
tests/run_tests.sh --tui              # explicitly open the menu
tests/run_tests.sh --batch            # baseline cases, no interaction
tests/run_tests.sh --batch --stress   # include timing and scale experiments
tests/run_tests.sh invalid            # text filter, also works with fifo/edf
tests/run_tests.sh --batch -l         # memory checks for small cases
CODEXION=./my_build tests/run_tests.sh # select another executable
python3 tests/self_test.py            # test the checker without Codexion
```

Without arguments, redirected output uses batch mode. Unless `CODEXION` is set, the runner builds with `make -C coders` when that Makefile exists. This checkout does not include a Codexion implementation: supply your binary before running simulation tests.

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

Execution prints one result per case, reasons for failures, warnings, and a summary. Each batch or repeat keeps its own directory under `tests/logs/run-*`; earlier logs are preserved. `.case` records the arguments and expectation, `.out` is stdout, `.err` is stderr, `.check`/`.check.err` record the checker output, and `.vg` is the optional Valgrind report. Ctrl-C interrupts execution.

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
| `policy` | A boundary input may be rejected with a diagnostic and nonzero status, or produce a valid simulation. Zero required compiles may also exit successfully without output. Inspect the warning against the implementation's documented policy. |

The 63 cases cover malformed input, negative values, single-coder shutdown, even and odd rings, both schedulers, cooldowns, zero-duration phases, repeated contention, burnout during different phases, scale, and tight boundaries. They are reasoned examples, not official evaluation cases. Generous baseline timings reduce timing sensitivity; they are still expectations to investigate, not proofs for every acquisition protocol. Tight feasible schedules are experiments because the acquisition policy and OS scheduling affect the outcome. Zero-duration phase and zero-required-count probes use `policy` because the subject does not precisely specify their validation. Ordinary baseline cases assume a zero dongle cooldown is supported. The suite does not impose an `INT_MAX` input limit: validate the range supported by your implementation without arithmetic overflow.

## What the checker can establish

- Log format, coder IDs, nondecreasing timestamps and per-coder action order.
- Minimum visible phase durations; excessive phase duration produces a warning.
- Impossible overlap between neighbouring compiles.
- Cooldown violations when a compile starts before the earliest possible previous release plus cooldown.
- Premature or late burnout, late compile starts, and output after burnout. A coder **can burn out while compiling** if its deadline expires during that phase.
- Missing compile starts on successful termination, crashes, execution failures, and hangs. A normal nonzero simulation exit status is a warning because the subject does not specify exit codes.

Timing checks assume log timestamps represent the corresponding phase transitions closely. Delayed logging can distort measured durations; a failure is evidence to investigate against an instrumented trace. The log does not identify individual dongles or exact release times. The checker uses `compile_start + time_to_compile` as the earliest possible release, not the debugging log timestamp: logging may be delayed after release. This avoids a false failure but cannot catch all late-release cooldown violations or misuse while taking dongles.

Final compile completion can be invisible when shutdown suppresses subsequent logs. The checker warns when it cannot infer completion from later timestamps; it cannot prove that the binary waited for the final phase to finish. Start counts are not completion counts.

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

The checker reads timestamps after the process exits; it cannot establish when a reader actually received buffered output. The subject's burnout reporting allowance is 10 ms; `SLACK` is an extra checker tolerance, not a subject requirement. Minimum phase and premature burnout checks allow 1 ms for timestamp rounding. Successful runs and clean detector reports provide evidence, not proof. Investigate failures with saved logs and repeat under ordinary machine load.

`self_test.py` exercises the checker with known valid and invalid synthetic traces and checks runner timeouts, exit handling, case validation, boundary policies, memory-check failures, and menu selection using controlled fixtures. It also validates all case definitions. It does not test a Codexion implementation.

Malformed case files and invalid runner settings are rejected before execution. A case file need not end with a newline. Exit status is 0 when no cases fail (warnings may remain), 1 for test failures, 2 for setup/input errors, and 130 for interruption. Inspect warnings: an accepted policy probe or an unobservable final completion is not proof of correctness.
