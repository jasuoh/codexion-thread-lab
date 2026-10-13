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
LEAKS=0
FILTER=""
INCLUDE_STRESS=0
MODE=batch
if [ "$#" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then MODE=tui; fi

usage() {
	cat <<EOF
Usage: $0 [--batch | --tui] [--stress] [-l] [FILTER]

  --tui       interactive selection (default in a terminal without arguments)
  --batch     run baseline cases without the menu
  --stress    include timing-boundary and many-thread experiments
  FILTER      select case lines containing this text (e.g. edf or invalid)
  -l, --leaks also run small cases under Valgrind
  -h, --help  show this help

Environment:
  CODEXION=path       executable (default: coders/codexion, built with make)
  CASES=path          case file (default: tests/cases.txt)
  CODEXION_LOGDIR=dir log parent directory (default: tests/logs)
  TIME_LIMIT=s       positive integer timeout in seconds (default: 20)
  SLACK=ms           extra deadline tolerance, nonnegative integer (default: 2)
  PHASE_TOL=ms       phase overrun warning threshold (default: 10)

Logs are preserved in a separate run-* directory for every batch.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		-l|--leaks) LEAKS=1 ;;
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

for setting in TIME_LIMIT SLACK PHASE_TOL; do
	value="${!setting}"
	if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
		echo "$setting must be an integer between 0 and 999999." >&2
		exit 2
	fi
done
[ "$TIME_LIMIT" -gt 0 ] || { echo "TIME_LIMIT must be positive." >&2; exit 2; }
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
if [ "$LEAKS" -eq 1 ] && ! command -v valgrind >/dev/null 2>&1; then
	echo "Valgrind is required when --leaks is selected." >&2; exit 2
fi
if [ -z "${CODEXION:-}" ] && [ -f "$ROOT/coders/Makefile" ]; then
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
LOGDIR="$(mktemp -d "$LOGDIR/run-XXXXXXXX")" || exit 2
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

LOG_RE='^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$'
pass=0
fail=0
warned=0
idx=0

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
	read -r -a argv <<< "$args"
	base="$LOGDIR/$(printf '%02d' "$idx")"
	out="$base.out"
	err="$base.err"
	reasons=""
	notes=""
	printf '%s | %s | %s\n' "$expect" "$args" "$desc" > "$base.case"
	run_limited "$TIME_LIMIT" "$BIN" "${argv[@]}" >"$out" 2>"$err"
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
	elif [ "$expect" = policy ] && [ "${argv[5]}" -eq 0 ]; then
		reasons+=$'\n'"FAIL: zero required compiles produced simulation output instead of stopping immediately"
	else
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

	reasons="$(printf '%s\n' "$reasons" | sed '/^$/d')"
	notes="$(printf '%s\n' "$notes" | sed '/^$/d')"
	label="$(printf '%02d %-8s %s' "$idx" "$expect" "$args")"
	if [ -n "$reasons" ]; then
		fail=$((fail + 1))
		printf '%s[FAIL]%s %s %s— %s%s\n' "$RED" "$RESET" "$label" "$DIM" "$desc" "$RESET"
		printf '%s\n' "$reasons" | head -n 5 | sed 's/^/         /'
		printf '         output: %s\n' "$out"
	else
		pass=$((pass + 1))
		printf '%s[ OK ]%s %s %s— %s%s\n' "$GREEN" "$RESET" "$label" "$DIM" "$desc" "$RESET"
	fi
	if [ -n "$notes" ]; then
		warned=$((warned + 1))
		printf '%s\n' "$notes" | head -n 3 | sed 's/^/         /'
	fi
done < "$CASES"

[ "$idx" -gt 0 ] || { echo "No cases matched: $FILTER" >&2; exit 2; }
printf '\npassed: %s%d%s   failed: %s%d%s   with warnings: %s%d%s\n' \
	"$GREEN" "$pass" "$RESET" "$RED" "$fail" "$RESET" "$YELLOW" "$warned" "$RESET"
printf 'logs: %s\n' "$LOGDIR"
[ "$fail" -eq 0 ]
