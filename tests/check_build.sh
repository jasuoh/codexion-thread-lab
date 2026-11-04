#!/usr/bin/env bash
# check_build.sh PROJECT_DIR - check a Codexion Makefile and sources against the subject.
#
# Works on a temporary copy, so the project's own build files are untouched.
# Checks: required rules (all, clean, fclean, re), NAME = codexion,
# -Wall -Wextra -Werror and -pthread, no relink when nothing changed,
# clean/fclean results, and norminette when it is installed.
# Prints FAIL / WARN / OK lines. Status: 0 pass, 1 failure, 2 usage error.
set -u

[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "Usage: $0 PROJECT_DIR" >&2; exit 2; }
SRC="$(cd "$1" && pwd)"
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
warn() { echo "WARN: $*"; }
ok() { echo "OK: $*"; }

[ -f "$SRC/Makefile" ] || { fail "no Makefile in $SRC"; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/codexion-build-XXXXXXXX")" || exit 2
trap 'rm -rf -- "$WORK"' EXIT
cp -R "$SRC/." "$WORK/" || exit 2
cd "$WORK" || exit 2
# Start from a clean copy, as an evaluator would after cloning.
find . -name '*.o' -delete 2>/dev/null
rm -f codexion

MAKE_CMD=(make --no-print-directory)
COMPILER_RE='(^|[[:space:]/])(cc|gcc|clang|c99)([[:space:]]|$)'

for rule in all clean fclean re; do
	if "${MAKE_CMD[@]}" -n "$rule" >/dev/null 2>&1; then
		ok "rule '$rule' exists"
	else
		fail "Makefile has no '$rule' rule (the subject requires \$(NAME), all, clean, fclean, re)"
	fi
done

# make has built-in rules (codexion from codexion.c), so look for NAME instead.
if "${MAKE_CMD[@]}" -pn 2>/dev/null | grep -Eq '^NAME[[:space:]]*:?=[[:space:]]*codexion[[:space:]]*$'; then
	ok "NAME is codexion"
else
	warn "no 'NAME = codexion' variable found (the subject names the rule \$(NAME))"
fi

# -n prints commands even when they are silenced with @.
commands="$("${MAKE_CMD[@]}" -n -B all 2>/dev/null | grep -E "$COMPILER_RE")"
if [ -z "$commands" ]; then
	warn "could not see compiler commands in 'make -n -B all'; flags were not checked"
else
	for flag in -Wall -Wextra -Werror; do
		if printf '%s\n' "$commands" | grep -Eq -- "(^|[[:space:]])$flag([[:space:]]|$)"; then
			ok "compiles with $flag"
		else
			fail "compiler commands do not use $flag"
		fi
	done
	if printf '%s\n' "$commands" | grep -Eq -- '(^|[[:space:]])-pthread([[:space:]]|$)'; then
		ok "builds with -pthread"
	elif printf '%s\n' "$commands" | grep -Eq -- '-lpthread'; then
		warn "links with -lpthread; -pthread is preferred for compiling and linking"
	else
		warn "no -pthread in compiler commands"
	fi
fi

if ! build_out="$("${MAKE_CMD[@]}" all 2>&1)"; then
	fail "make all failed:"
	printf '%s\n' "$build_out" | tail -n 15 | sed 's/^/      /'
	exit 1
fi
if [ -x codexion ]; then ok "make all builds ./codexion"; else fail "make all did not create an executable named codexion"; fi
if printf '%s\n' "$build_out" | grep -Eiq 'warning:'; then
	warn "the build printed compiler warnings"
fi

if "${MAKE_CMD[@]}" -n all 2>/dev/null | grep -Eq "$COMPILER_RE"; then
	fail "make all relinks or recompiles although nothing changed"
else
	ok "no relink when nothing changed"
fi

"${MAKE_CMD[@]}" clean >/dev/null 2>&1 || fail "make clean failed"
if [ -n "$(find . -name '*.o' -print -quit)" ]; then fail "object files remain after make clean"; else ok "make clean removes object files"; fi
[ -x codexion ] || warn "make clean also removed the executable (fclean should do that)"
"${MAKE_CMD[@]}" fclean >/dev/null 2>&1 || fail "make fclean failed"
if [ -e codexion ]; then fail "codexion remains after make fclean"; else ok "make fclean removes the executable"; fi
if "${MAKE_CMD[@]}" re >/dev/null 2>&1 && [ -x codexion ]; then ok "make re rebuilds"; else fail "make re did not rebuild codexion"; fi

if command -v norminette >/dev/null 2>&1; then
	mapfile -t files < <(find . \( -name '*.c' -o -name '*.h' \) -not -path './.git/*' | sort)
	if [ "${#files[@]}" -eq 0 ]; then
		warn "no .c or .h files for norminette"
	elif norm_out="$(norminette "${files[@]}" 2>&1)"; then
		ok "norminette passes"
	else
		fail "norminette reports errors:"
		printf '%s\n' "$norm_out" | grep -v ': OK!$' | head -n 15 | sed 's/^/      /'
	fi
else
	warn "norminette is not installed; Norm not checked (pip install norminette)"
fi

[ "$fails" -eq 0 ]
