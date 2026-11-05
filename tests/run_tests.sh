#!/usr/bin/env bash
# Run Codexion cases, or open the optional terminal selector.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$DIR")"
BIN="${CODEXION:-$ROOT/coders/codexion}"
CASES="${CASES:-$DIR/cases.txt}"
LOGDIR="${CODEXION_LOGDIR:-$DIR/logs}"
SLACK="${SLACK:-2}"
PHASE_TOL="${PHASE_TOL:-10}"
TIME_LIMIT="${TIME_LIMIT:-20}"
CPU_WARN="${CPU_WARN:-100}"
LATENCY_WARN="${LATENCY_WARN:-10}"
REPEAT="${REPEAT:-1}"
RACE_TOOL="${RACE_TOOL:-drd}"
RACE_MAX_CODERS="${RACE_MAX_CODERS:-8}"
PROJECT="${CODEXION_SRC:-}"
LEAKS=0
RACES=0
BUILD_CHECK=1
ORIGINAL_ARGS=("$@")
FILTER=""
INCLUDE_STRESS=0
MODE=batch
if [ "$#" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then MODE=tui; fi

usage() {
	cat <<EOF
Usage: $0 [--batch | --tui] [--stress] [-l] [-r] [--repeat N] [--no-build-check] [FILTER]

  --tui            interactive selection (default in a terminal without arguments)
  --batch          run baseline cases without the menu
  --stress         include timing-boundary and many-thread experiments
  FILTER           select case lines containing this text (e.g. edf or invalid)
  -l, --leaks      also run small cases under Valgrind memcheck
  -r, --races      also run small simulations under a Valgrind race detector
  --repeat N       run the selected cases N times (1-100) in one log directory
  --no-build-check skip the Makefile/Norm check of the project sources
  -h, --help       show this help

Environment:
  CODEXION=path       executable (default: coders/codexion, built with make)
  CASES=path          case file (default: tests/cases.txt)
  CODEXION_LOGDIR=dir log parent directory (default: tests/logs)
  TIME_LIMIT=s       positive integer timeout in seconds (default: 20)
  SLACK=ms           extra deadline tolerance, nonnegative integer (default: 2)
  PHASE_TOL=ms       phase overrun warning threshold (default: 10)
  CPU_WARN=percent   warn when CPU time exceeds this share of wall time (default: 100, 0 disables)
  LATENCY_WARN=ms    warn when the burnout line reaches the terminal later (default: 10, 0 disables)
  REPEAT=n           same as --repeat (default: 1)
  RACE_TOOL=name     drd or helgrind for --races (default: drd)
  RACE_MAX_CODERS=n  largest coder count run under --races (default: 8)
  CODEXION_SRC=dir   project directory for the Makefile/Norm check
                     (default: coders/ when CODEXION is not set)

Every batch gets its own logs directory named run-DATE-TIME-ID with run.info
(binary, checksum, settings, machine) and summary.txt; logs/latest points to it.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-l|--leaks) LEAKS=1 ;;
		-r|--races) RACES=1 ;;
		--no-build-check) BUILD_CHECK=0 ;;
		--repeat)
			[ $# -ge 2 ] || { echo "--repeat needs a number." >&2; exit 2; }
			REPEAT="$2"; shift ;;
		--repeat=*) REPEAT="${1#--repeat=}" ;;
		--batch) MODE=batch ;;
		--tui) MODE=tui ;;
		--stress) INCLUDE_STRESS=1 ;;
		-*) echo "Unknown option: $1" >&2; exit 2 ;;
		*)
			[ -z "$FILTER" ] || { echo "Use one text filter." >&2; exit 2; }
			FILTER="$1" ;;
	esac
	shift
done

for setting in TIME_LIMIT SLACK PHASE_TOL CPU_WARN LATENCY_WARN REPEAT RACE_MAX_CODERS; do
	value="${!setting}"
	if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
		echo "$setting must be an integer between 0 and 999999." >&2
		exit 2
	fi
done
[ "$TIME_LIMIT" -gt 0 ] || { echo "TIME_LIMIT must be positive." >&2; exit 2; }
[ "$REPEAT" -ge 1 ] && [ "$REPEAT" -le 100 ] || { echo "REPEAT must be between 1 and 100." >&2; exit 2; }
case "$RACE_TOOL" in drd|helgrind) ;; *) echo "RACE_TOOL must be drd or helgrind." >&2; exit 2 ;; esac
[ -r "$CASES" ] || { echo "Cannot read cases: $CASES" >&2; exit 2; }

# Validate the whole case file before running any executable.
awk -F '|' '
/^[[:space:]]*(#|$)/ { next }
{
 for (i=1; i<=NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
 if (NF != 3 || $1 !~ /^(invalid|survive|burnout|any|policy)$/ || $3 == "") {
  print "Invalid case row at line " NR > "/dev/stderr"; bad=1; next
 }
 if ($1 != "invalid") {
  count=split($2, args, /[[:space:]]+/)
  valid=(count == 8 && args[1] ~ /^[0-9]+$/ && args[1]+0 > 0 && args[8] ~ /^(fifo|edf)$/)
  for (i=2; i<=7; i++) if (args[i] !~ /^[0-9]+$/) valid=0
  if (!valid) { print "Invalid simulation arguments at line " NR > "/dev/stderr"; bad=1 }
 }
}
END { exit bad }
' "$CASES" || exit 2

if [ "$MODE" = tui ]; then
	menu_args=()
	[ "$LEAKS" -eq 0 ] || menu_args+=(--leaks)
	[ "$RACES" -eq 0 ] || menu_args+=(--races)
	[ "$INCLUDE_STRESS" -eq 0 ] || menu_args+=(--stress)
	[ -z "$FILTER" ] || menu_args+=(--filter "$FILTER")
	exec python3 "$DIR/menu.py" "${menu_args[@]}"
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
	RED=""; GREEN=""; YELLOW=""; DIM=""; RESET=""
fi

TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD=gtimeout
else echo "timeout or gtimeout is required." >&2; exit 2
fi
if [ $((LEAKS + RACES)) -gt 0 ] && ! command -v valgrind >/dev/null 2>&1; then
	echo "Valgrind is required for --leaks and --races." >&2; exit 2
fi
if [ -z "${CODEXION:-}" ] && [ -f "$ROOT/coders/Makefile" ]; then
	[ -n "$PROJECT" ] || PROJECT="$ROOT/coders"
	make -s -C "$ROOT/coders" || { echo "Build failed." >&2; exit 2; }
fi
if [ ! -f "$BIN" ] || [ ! -x "$BIN" ]; then
	echo "Binary not found or not executable: $BIN" >&2
	echo "Build it first, or set CODEXION=/path/to/codexion." >&2
	exit 2
fi
# timeout searches PATH for bare filenames; make relative paths explicit.
case "$BIN" in /*) ;; *) BIN="$PWD/$BIN" ;; esac
mkdir -p "$LOGDIR" || exit 2
LOGPARENT="$LOGDIR"
LOGDIR="$(mktemp -d "$LOGDIR/run-$(date +%Y%m%d-%H%M%S)-XXXX")" || exit 2
ln -sfn "$(basename "$LOGDIR")" "$LOGPARENT/latest" 2>/dev/null || true

checksum() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	else echo unavailable
	fi
}

git_state() {
	local dir="$1" commit dirty=""
	commit="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" || { echo "not a git checkout"; return; }
	[ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || dirty=" (uncommitted changes)"
	echo "$commit on $(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)$dirty"
}

# Everything needed to trace a result back to the build and settings that produced it.
{
	echo "started:     $(date '+%Y-%m-%d %H:%M:%S %z')"
	echo "command:     $0 ${ORIGINAL_ARGS[*]}"
	echo "binary:      $BIN"
	echo "modified:    $(date -r "$BIN" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
	echo "sha256:      $(checksum "$BIN")"
	echo "binary repo: $(git_state "$(dirname "$BIN")")"
	echo "project:     ${PROJECT:-not checked}"
	echo "tester repo: $(git_state "$DIR")"
	echo "cases:       $CASES"
	echo "filter:      ${FILTER:-(none)}  stress: $INCLUDE_STRESS  repeat: $REPEAT"
	echo "valgrind:    leaks=$LEAKS races=$RACES ($RACE_TOOL, up to $RACE_MAX_CODERS coders)"
	echo "settings:    TIME_LIMIT=$TIME_LIMIT SLACK=$SLACK PHASE_TOL=$PHASE_TOL CPU_WARN=$CPU_WARN LATENCY_WARN=$LATENCY_WARN"
	echo "machine:     $(uname -srm) cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo ?)"
	echo "load:        $(uptime 2>/dev/null | sed 's/.*load average[s]*: //')"
} > "$LOGDIR/run.info"
: > "$LOGDIR/summary.txt"
exec 3>>"$LOGDIR/summary.txt"
trap 'printf "\nInterrupted. Logs: %s\n" "$LOGDIR"; exit 130' INT
trap 'printf "\nTerminated. Logs: %s\n" "$LOGDIR"; exit 143' TERM

run_limited() {
	local limit="$1"
	shift
	"$TIMEOUT_CMD" -k 2s "$limit" "$@" </dev/null
}

describe_status() {
	local rc="$1" limit="$2"
	case "$rc" in
		124) echo "did not terminate within ${limit}s (hang or deadlock?)" ;;
		125|126|127) echo "could not execute the test reliably (status $rc)" ;;
		*) if [ "$rc" -gt 128 ]; then echo "terminated by signal or signal-like status $rc"; fi ;;
	esac
}

# Print a result line in color, and without color to summary.txt.
result_line() {
	local color="$1" tag="$2"
	shift 2
	printf '%s[%s]%s %s\n' "$color" "$tag" "$RESET" "$*"
	printf '[%s] %s\n' "$tag" "$*" | sed $'s/\033\\[[0-9;]*m//g' >&3
}

details() {
	sed 's/^/         /' | tee -a /dev/fd/3
}

LOG_RE='^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$'
pass=0
fail=0
warned=0
idx=0

# Static check of the linked binary: functions and globals the subject forbids.
if command -v nm >/dev/null 2>&1; then
	fn_report="$(python3 "$DIR/check_functions.py" "$BIN" 2>&1)"
	fn_rc=$?
	printf '%s\n' "$fn_report" > "$LOGDIR/functions.check"
	if [ "$fn_rc" -eq 1 ]; then
		fail=$((fail + 1))
		result_line "$RED" FAIL "allowed functions and globals (subject rules)"
		printf '%s\n' "$fn_report" | grep '^FAIL' | head -n 8 | details
	elif [ "$fn_rc" -ne 0 ]; then
		result_line "$YELLOW" WARN "function check could not run (see $LOGDIR/functions.check)"
	else
		result_line "$GREEN" " OK " "allowed functions and globals (subject rules)"
	fi
	if printf '%s\n' "$fn_report" | grep -q '^WARN'; then
		warned=$((warned + 1))
		printf '%s\n' "$fn_report" | grep '^WARN' | head -n 3 | details
	fi
fi

# Makefile rules, flags, relinking and Norm, checked on a copy of the project.
if [ "$BUILD_CHECK" -eq 1 ] && [ -n "$PROJECT" ]; then
	build_report="$("$DIR/check_build.sh" "$PROJECT" 2>&1)"
	build_rc=$?
	printf '%s\n' "$build_report" > "$LOGDIR/build.check"
	if [ "$build_rc" -eq 0 ]; then
		result_line "$GREEN" " OK " "Makefile and Norm ($PROJECT)"
	else
		fail=$((fail + 1))
		result_line "$RED" FAIL "Makefile and Norm ($PROJECT)"
		printf '%s\n' "$build_report" | grep -E '^FAIL|^      ' | head -n 10 | details
	fi
	if printf '%s\n' "$build_report" | grep -q '^WARN'; then
		warned=$((warned + 1))
		printf '%s\n' "$build_report" | grep '^WARN' | head -n 3 | details
	fi
fi

total=0
for ((rep = 1; rep <= REPEAT; rep++)); do
idx=0
[ "$REPEAT" -eq 1 ] || printf '\n--- repetition %d/%d ---\n' "$rep" "$REPEAT" | tee -a /dev/fd/3
while IFS='|' read -r expect args desc || [ -n "$expect$args$desc" ]; do
	expect="$(printf '%s' "$expect" | tr -d '[:space:]')"
	case "$expect" in ''|\#*) continue ;; esac
	args="$(printf '%s' "$args" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	desc="$(printf '%s' "$desc" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	if [ -n "$FILTER" ]; then
		case "$expect | $args | $desc" in *"$FILTER"*) ;; *) continue ;; esac
	elif [ "$INCLUDE_STRESS" -eq 0 ]; then
		case "$desc" in *"[stress]"*) continue ;; esac
	fi
	idx=$((idx + 1))
	total=$((total + 1))
	read -r -a argv <<< "$args"
	prefix="$(printf '%02d-%s' "$idx" "$expect")"
	[ "$REPEAT" -eq 1 ] || prefix="$(printf 'r%02d-%s' "$rep" "$prefix")"
	base="$LOGDIR/$prefix"
	out="$base.out"
	err="$base.err"
	reasons=""
	notes=""
	{
		printf '%s | %s | %s\n' "$expect" "$args" "$desc"
		printf 'started: %s  repetition: %d/%d\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rep" "$REPEAT"
		printf 'command: %s %s\n' "$BIN" "$args"
	} > "$base.case"
	# stamp.py gives the binary a terminal, as in an interactive shell, and
	# records when each line arrives. The time keyword reports CPU used by
	# waited-for descendants, including the binary started by timeout.
	{ TIMEFORMAT='%R %U %S'; time python3 "$DIR/stamp.py" "$base.arrivals" -- \
		"$TIMEOUT_CMD" -k 2s "$TIME_LIMIT" "$BIN" "${argv[@]}" </dev/null >"$out" 2>"$err"; } 2>"$base.time"
	rc=$?
	status="$(describe_status "$rc" "$TIME_LIMIT")"
	[ -z "$status" ] || reasons="FAIL: $status"

	if [ "$expect" = invalid ]; then
		if grep -Eq "$LOG_RE" "$out" "$err"; then
			reasons+=$'\n'"FAIL: simulation output printed for invalid input"
		fi
		[ "$rc" -ne 0 ] || notes+=$'\n'"WARN: exit status 0 for invalid input (not specified by the subject)"
		[ -s "$err" ] || [ -s "$out" ] || notes+=$'\n'"WARN: no rejection diagnostic; rejection cannot be confirmed"
	elif [ "$expect" = policy ] && ! grep -Eq "$LOG_RE" "$out" "$err"; then
		# Acceptance of these boundary inputs is a documented implementation choice.
		if [ "$rc" -ne 0 ] && { [ -s "$err" ] || [ -s "$out" ]; }; then
			notes+=$'\n'"WARN: boundary input rejected; compare with the implementation's documented policy"
		elif [ "${argv[5]}" -eq 0 ] && [ ! -s "$out" ] && [ "$rc" -eq 0 ]; then
			notes+=$'\n'"WARN: zero required compiles: empty successful run accepted"
		else
			reasons+=$'\n'"FAIL: boundary input produced neither a valid simulation nor a clear rejection"
		fi
	elif [ "$expect" = policy ] && [ "${argv[5]}" -eq 0 ] && grep -Eq '^[0-9]+ [0-9]+ burned out$' "$out" "$err"; then
		reasons+=$'\n'"FAIL: zero required compiles ended in a burnout instead of stopping immediately"
	else
		if [ "$expect" = policy ] && [ "${argv[5]}" -eq 0 ]; then
			notes+=$'\n'"WARN: zero required compiles still produced simulation output before stopping"
		fi
		[ "$rc" -eq 0 ] || notes+=$'\n'"WARN: simulation exited with status $rc (exit codes are not specified by the subject)"
		check_expect="$expect"
		[ "$expect" != policy ] || check_expect=any
		result="$(awk -v n="${argv[0]}" -v ttb="${argv[1]}" -v ttc="${argv[2]}" \
			-v ttd="${argv[3]}" -v ttr="${argv[4]}" -v req="${argv[5]}" \
			-v cd="${argv[6]}" -v expect="$check_expect" -v slack="$SLACK" \
			-v ptol="$PHASE_TOL" -f "$DIR/check_log.awk" "$out" 2>"$base.check.err")"
		check_rc=$?
		printf '%s\n' "$result" > "$base.check"
		if [ "$check_rc" -ne 0 ] && ! printf '%s\n' "$result" | grep -q '^FAIL'; then
			reasons+=$'\n'"FAIL: log checker could not run (see $base.check.err)"
		fi
		reasons+=$'\n'"$(printf '%s\n' "$result" | grep '^FAIL' || true)"
		notes+=$'\n'"$(printf '%s\n' "$result" | grep '^WARN' || true)"
		if [ "$LATENCY_WARN" -gt 0 ] && [ -z "$status" ]; then
			python3 "$DIR/stamp.py" --analyze "$out" "$base.arrivals" "$LATENCY_WARN" > "$base.latency" 2>&1
			notes+=$'\n'"$(grep '^WARN' "$base.latency" || true)"
		fi
	fi

	if [ "$CPU_WARN" -gt 0 ] && [ -z "$status" ]; then
		cpu_note="$(tr ',' '.' < "$base.time" | awk -v limit="$CPU_WARN" '
			NF == 3 && $1 >= 0.5 && $2 + $3 > $1 * limit / 100 {
				printf "WARN: used %.2fs CPU in %.2fs wall time (%d%%): busy-waiting?", $2 + $3, $1, 100 * ($2 + $3) / $1
			}')"
		[ -z "$cpu_note" ] || notes+=$'\n'"$cpu_note"
	fi

	if [ "$LEAKS" -eq 1 ] && [ -z "$status" ] && { [ "$expect" = invalid ] || [ "${argv[0]}" -le 20 ]; }; then
		vg_limit=$((TIME_LIMIT * 5))
		run_limited "$vg_limit" valgrind -q --leak-check=full --show-leak-kinds=all \
			--errors-for-leak-kinds=all --error-exitcode=42 "$BIN" "${argv[@]}" >/dev/null 2>"$base.vg"
		vrc=$?
		vstatus="$(describe_status "$vrc" "$vg_limit")"
		if [ "$vrc" -eq 42 ]; then
			reasons+=$'\n'"FAIL: Valgrind reported leaks or memory errors (see $base.vg)"
		elif [ -n "$vstatus" ]; then
			reasons+=$'\n'"FAIL: Valgrind check incomplete: $vstatus (see $base.vg)"
		elif [ "$vrc" -ne 0 ] && [ "$expect" != invalid ] && [ "$expect" != policy ]; then
			notes+=$'\n'"WARN: Valgrind execution returned status $vrc; inspect $base.vg"
		fi
	fi

	if [ "$RACES" -eq 1 ] && [ -z "$status" ] && [ "$expect" != invalid ] && [ "${argv[0]}" -le "$RACE_MAX_CODERS" ] \
		&& grep -Eq "$LOG_RE" "$out"; then
		race_limit=$((TIME_LIMIT * 10))
		run_limited "$race_limit" valgrind -q --tool="$RACE_TOOL" --error-exitcode=43 \
			"$BIN" "${argv[@]}" >/dev/null 2>"$base.race"
		rrc=$?
		rstatus="$(describe_status "$rrc" "$race_limit")"
		if [ "$rrc" -eq 43 ]; then
			reasons+=$'\n'"FAIL: $RACE_TOOL reported data races or lock errors (see $base.race)"
		elif [ -n "$rstatus" ]; then
			notes+=$'\n'"WARN: $RACE_TOOL check incomplete: $rstatus (see $base.race)"
		fi
	fi

	reasons="$(printf '%s\n' "$reasons" | sed '/^$/d')"
	notes="$(printf '%s\n' "$notes" | sed '/^$/d')"
	printf 'result: %s\n' "$([ -n "$reasons" ] && echo FAIL || echo OK)" >> "$base.case"
	printf '%s\n' "$reasons" "$notes" | sed '/^$/d' >> "$base.case"
	label="$(printf '%02d %-8s %s' "$idx" "$expect" "$args")"
	if [ -n "$reasons" ]; then
		fail=$((fail + 1))
		result_line "$RED" FAIL "$label ${DIM}— $desc$RESET"
		printf '%s\n' "$reasons" | head -n 5 | details
		printf 'logs: %s.*\n' "$base" | details
	else
		pass=$((pass + 1))
		result_line "$GREEN" " OK " "$label ${DIM}— $desc$RESET"
	fi
	if [ -n "$notes" ]; then
		warned=$((warned + 1))
		printf '%s\n' "$notes" | head -n 3 | details
	fi
done < "$CASES"
done

[ "$total" -gt 0 ] || { echo "No cases matched: $FILTER" >&2; exit 2; }
printf '\npassed: %s%d%s   failed: %s%d%s   with warnings: %s%d%s\n' \
	"$GREEN" "$pass" "$RESET" "$RED" "$fail" "$RESET" "$YELLOW" "$warned" "$RESET"
printf 'passed: %d   failed: %d   with warnings: %d\nfinished: %s\n' \
	"$pass" "$fail" "$warned" "$(date '+%Y-%m-%d %H:%M:%S')" >&3
printf 'logs: %s\n' "$LOGDIR"
[ "$fail" -eq 0 ]
