# check_log.awk - validate the output of one Codexion run.
#
# Usage:
#   awk -v n=5 -v ttb=800 -v ttc=200 -v ttd=200 -v ttr=200 -v req=5 -v cd=0 \
#       -v expect=survive [-v slack=2] [-v ptol=10] -f check_log.awk run.log
#
#   n ttb ttc ttd ttr req cd  the program arguments, in subject order
#   expect                    survive | burnout | any
#   slack                     ms of tolerance for rounding and OS jitter
#   ptol                      ms a phase may overrun before a WARN is printed
#
# Prints FAIL / WARN / INFO lines. Status: 0 pass, 1 failure, 2 invalid configuration.
#
# Observable checks derived from the subject and the guide's log interpretation:
# Timing checks assume log timestamps closely represent phase transitions.
#   - every line matches "timestamp_in_ms X <message>" with a known message
#   - timestamps never go backwards, coder numbers are within 1..n
#   - per coder: take, take, compiling, debugging, refactoring, take, ...
#   - phases are not shorter than time_to_compile / _debug / _refactor
#   - two coders that share a dongle never compile at the same time
#   - compile starts respect the earliest possible release plus cooldown
#   - nobody starts compiling after their deadline without a burnout
#   - a burnout is not premature and is printed within 10 ms of the deadline
#   - nothing is printed after "burned out"
#   - survive: no burnout and every coder started at least req compiles
#     (final completion may not be visible in the log)
#
# What it can NOT check from the log alone: which exact dongle was taken,
# FIFO/EDF order, data races, leaks. Use helgrind/drd/tsan/valgrind for those.

BEGIN {
    config_bad = 0
    if (n !~ /^[0-9]+$/ || n + 0 < 1 || ttb !~ /^[0-9]+$/ ||
        ttc !~ /^[0-9]+$/ || ttd !~ /^[0-9]+$/ || ttr !~ /^[0-9]+$/ ||
        req !~ /^[0-9]+$/ || cd !~ /^[0-9]+$/ ||
        expect !~ /^(survive|burnout|any)$/ ||
        (slack != "" && slack !~ /^[0-9]+$/) ||
        (ptol != "" && ptol !~ /^[0-9]+$/)) {
        print "FAIL: invalid or missing checker configuration"
        config_bad = 1
        exit 2
    }
	if (slack == "")
		slack = 2
	if (ptol == "")
		ptol = 10
	n += 0; ttb += 0; ttc += 0; ttd += 0; ttr += 0; req += 0; cd += 0
	slack += 0; ptol += 0
	for (i = 1; i <= n; i++) {
		state[i] = "start"
		takes[i] = 0
		last[i] = 0
		comp[i] = -1
		mark[i] = 0
		count[i] = 0
	}
	fails = 0
	warns = 0
	burned = 0
	prev = -1
}

function fail(msg) {
	fails++
	if (fails <= 10)
		print "FAIL: " msg
}

function warn(msg) {
	warns++
	if (warns <= 5)
		print "WARN: " msg
}

function left(x) {
	return (x == 1 ? n : x - 1)
}

function right(x) {
	return (x == n ? 1 : x + 1)
}

function on_take(t, x) {
	if (state[x] == "refactoring" && t + 1 < mark[x] + ttr)
		fail(ctx "refactoring lasted only " (t - mark[x]) " ms (time_to_refactor = " ttr ")")
	if (state[x] == "start" || state[x] == "refactoring") {
		state[x] = "taking"
		takes[x] = 1
	} else if (state[x] == "taking" && takes[x] == 1) {
		takes[x] = 2
		if (n == 1)
			fail(ctx "there is only one dongle, but the coder took two")
	} else
		fail(ctx "took a dongle while " state[x] " (a coder takes exactly two before compiling)")
}

# Coder x starts compiling at t. Dongle sharing with coder k:
#   k still compiling        -> the same dongle is in two hands
#   earliest possible release + cd is in the future -> reuse is too early
# "k still compiling" only fails when k's compile time has not elapsed yet,
# because a correct program may release before printing "is debugging".
function check_dongle(t, x, k) {
	if (k != x && state[k] == "compiling" && t + 1 < comp[k] + ttc)
		fail(ctx "coder " k " is still compiling (since " comp[k] ") and shares a dongle with coder " x)
	if (comp[k] >= 0 && t + 1 < comp[k] + ttc + cd)
		fail(ctx "dongle cannot finish compiling and cooldown before " (comp[k] + ttc + cd))
}

function on_compile(t, x,    gap) {
	if (state[x] != "taking" || takes[x] != 2)
		fail(ctx "started compiling without two \"has taken a dongle\" lines first")
	gap = t - last[x]
	if (gap > ttb + slack)
		fail(ctx "started compiling " gap " ms after its previous compile start (time_to_burnout = " ttb "): it should have burned out")
	check_dongle(t, x, x)
	check_dongle(t, x, left(x))
	if (right(x) != left(x))
		check_dongle(t, x, right(x))
	state[x] = "compiling"
	takes[x] = 0
	comp[x] = t
	last[x] = t
	count[x]++
}

function on_debug(t, x,    d) {
	if (state[x] != "compiling")
		fail(ctx "debugging without compiling first")
	else {
		d = t - comp[x]
		if (d + 1 < ttc)
			fail(ctx "compiling lasted only " d " ms (time_to_compile = " ttc ")")
		else if (d > ttc + ptol)
			warn(ctx "compiling lasted " d " ms (time_to_compile = " ttc ")")
	}
	state[x] = "debugging"
	mark[x] = t
}

function on_refactor(t, x,    d) {
	if (state[x] != "debugging")
		fail(ctx "refactoring without debugging first")
	else {
		d = t - mark[x]
		if (d + 1 < ttd)
			fail(ctx "debugging lasted only " d " ms (time_to_debug = " ttd ")")
		else if (d > ttd + ptol)
			warn(ctx "debugging lasted " d " ms (time_to_debug = " ttd ")")
	}
	state[x] = "refactoring"
	mark[x] = t
}

function on_burnout(t, x,    d, i) {
	burned = 1
	burn_x = x
	burn_t = t
	d = t - last[x]
	if (d + 1 < ttb)
		fail(ctx "burned out only " d " ms after its last compile start (time_to_burnout = " ttb ")")
	else if (d > ttb + 10 + slack)
		fail(ctx "burnout printed " (d - ttb) " ms after the deadline (limit: 10 ms)")
	for (i = 1; i <= n; i++)
		if (i != x && t - last[i] > ttb + 10 + slack)
			fail(ctx "coder " i " passed its deadline at " (last[i] + ttb) " but its burnout was never printed")
}

{
	ctx = "line " NR " \"" $0 "\": "
	if (burned) {
		fail(ctx "printed after the burnout")
		next
	}
	if ($0 !~ /^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$/) {
		fail(ctx "does not match the log format")
		next
	}
	t = $1 + 0
	x = $2 + 0
	if (x < 1 || x > n) {
		fail(ctx "coder number outside 1.." n)
		next
	}
	if (t < prev)
		fail(ctx "timestamp goes backwards (previous line: " prev ")")
	if (NR == 1 && t > 20 && $3 != "burned")
		warn(ctx "first timestamp is far from 0 (timestamps must be relative to the simulation start)")
	prev = t
	if ($3 == "has")
		on_take(t, x)
	else if ($4 == "compiling")
		on_compile(t, x)
	else if ($4 == "debugging")
		on_debug(t, x)
	else if ($4 == "refactoring")
		on_refactor(t, x)
	else
		on_burnout(t, x)
}

END {
	if (config_bad) exit 2
	ctx = "end of log: "
	if (NR == 0)
		fail(ctx "no output at all")
	if (expect == "survive" || (expect == "any" && !burned)) {
		if (burned)
			fail(ctx "unexpected burnout of coder " burn_x " at " burn_t " ms")
		else {
			for (i = 1; i <= n; i++) {
				completed = count[i]
				if (state[i] == "compiling" && prev + 1 < comp[i] + ttc)
					completed--
				if (count[i] < req)
					fail(ctx "coder " i " started only " count[i] " compiles, " req " required")
				else if (completed < req)
					warn(ctx "final compile completion for coder " i " is not visible; logs alone cannot confirm completion")
				if (prev - last[i] > ttb + 10 + slack)
					fail(ctx "coder " i " passed its deadline at " (last[i] + ttb) " without a burnout")
			}
		}
	} else if (expect == "burnout" && !burned)
		fail(ctx "expected a burnout, but none was printed")
	lo = -1
	hi = 0
	for (i = 1; i <= n; i++) {
		if (lo < 0 || count[i] < lo)
			lo = count[i]
		if (count[i] > hi)
			hi = count[i]
	}
	print "INFO: " NR " lines, compile starts per coder: min " lo ", max " hi \
		(burned ? ", coder " burn_x " burned out at " burn_t : "")
	exit (fails > 0)
}
