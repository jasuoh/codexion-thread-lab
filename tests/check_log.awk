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
#   aborted                   1 when the run crashed or timed out: skip end-of-log
#                             completeness checks (the runner reports the crash)
#
# Prints FAIL / WARN / INFO lines, HINT lines (likely causes of a failure,
# once per kind) and DIAG lines (a diagnosis computed from the log, e.g. for
# an unexpected burnout). Status: 0 pass, 1 failure, 2 invalid configuration.
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
#   - no compile starts long after every coder completed req compiles (WARN)
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
        (ptol != "" && ptol !~ /^[0-9]+$/) || (aborted != "" && aborted !~ /^[01]$/)) {
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
	reached = 0
	maxpar = 0
	ncomp = 0
	done_t = -1
	fails = 0
	warns = 0
	burned = 0
	prev = -1
}

function fail(msg, key) {
	fails++
	if (fails <= 10) {
		print "FAIL: " msg
		if (key != "" && !(key in hinted)) {
			hinted[key] = 1
			hint(key)
		}
	}
}

# Likely causes of each kind of failure, printed once after its first FAIL.
function hint(key) {
	if (key == "format")
		print "HINT: the format is exactly \"<ms> <coder> <message>\": one space between fields, no colors, no trailing spaces, coder numbers from 1. Debug prints on stdout also break it; use stderr for those."
	else if (key == "backwards")
		print "HINT: read the clock inside the print mutex, just before printing. A thread that reads the time, is preempted, and prints after another thread produces timestamps that go backwards."
	else if (key == "order")
		print "HINT: each coder logs: has taken a dongle, has taken a dongle, is compiling, is debugging, is refactoring, then again. Check that every state change is logged once, by the coder itself, in this order."
	else if (key == "short")
		print "HINT: a phase ended too early. Sleep until an absolute target (phase_start + duration) and re-check the clock; check ms/us units (usleep takes microseconds); make sure stop does not shorten a phase that is still logged."
	else if (key == "shared")
		print "HINT: two neighbours compiled at the same time, so one dongle was in two hands. Check that the dongle state is read and written only under its mutex, and that it is released after the compile has finished, not before."
	else if (key == "cooldown")
		print "HINT: a dongle was reused before release + dongle_cooldown. Set available_at = release_time + cooldown under the dongle mutex when it is released, and check it in the wait predicate before granting (to both dongles)."
	else if (key == "late_start")
		print "HINT: a coder compiled after its deadline instead of burning out. Either the monitor is not checking often enough, or a coder resets last_compile_start after its deadline passed. Check the deadline and stop under the same lock when a compile starts."
	else if (key == "early_burnout")
		print "HINT: burnout counts from the START of the last compile (or the simulation start). Check that last_compile_start is set when compiling starts, initialized to the start time, and read under its mutex."
	else if (key == "late_burnout")
		print "HINT: the burnout line came more than 10 ms after the deadline. Check the monitor's sleep (about 1 ms), that it is not blocked on a lock held by a sleeping coder, and that nothing sleeps while holding the print mutex."
	else if (key == "missed_burnout")
		print "HINT: the monitor reported a coder whose deadline came later. Check every coder on each pass and compare now - last_compile_start for each; a stale copy of last_compile_start or a monitor that skips coders reports the wrong one."
	else if (key == "after")
		print "HINT: nothing may be printed after a burnout. Set the stop flag before printing \"burned out\", and have every print check stop under the print mutex."
	else if (key == "one_dongle")
		print "HINT: a single coder has a single dongle on the table, so it can take it at most once and can never compile. Do not let the left and right dongle point to the same dongle twice."
	else if (key == "count")
		print "HINT: the simulation stopped before every coder reached number_of_compiles_required. Check the monitor's completion condition (all coders, not one) and how compile counts are updated."
	else if (key == "no_burnout")
		print "HINT: a burnout was expected but none was printed. Check that the monitor runs during the whole simulation and compares now - last_compile_start with time_to_burnout."
	else if (key == "no_output")
		print "HINT: nothing was printed. Check the process exit status above (crash?), and whether output stays in a buffer: printf on a terminal is line-buffered, so end every line with \\n."
}

function diag(msg) {
	print "DIAG: " msg
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
		fail(ctx "refactoring too short: expected at least " ttr " ms (time_to_refactor), got " (t - mark[x]) " ms", "short")
	if (state[x] == "start" || state[x] == "refactoring") {
		state[x] = "taking"
		takes[x] = 1
		take1[x] = t
	} else if (state[x] == "taking" && takes[x] == 1) {
		takes[x] = 2
		if (n == 1)
			fail(ctx "second dongle taken: expected at most one \"has taken a dongle\" (one coder, one dongle), got two", "one_dongle")
	} else
		fail(ctx "dongle taken while " state[x] ": expected exactly two takes after refactoring and before compiling", "order")
}

# Coder x starts compiling at t. Dongle sharing with coder k:
#   k still compiling        -> the same dongle is in two hands
#   earliest possible release + cd is in the future -> reuse is too early
# "k still compiling" only fails when k's compile time has not elapsed yet,
# because a correct program may release before printing "is debugging".
function check_dongle(t, x, k) {
	if (k != x && state[k] == "compiling" && t + 1 < comp[k] + ttc) {
		fail(ctx "coder " k " is still compiling (since " comp[k] ") and shares a dongle with coder " x \
			": expected this start at " (comp[k] + ttc + cd) " or later, got " t, "shared")
		return
	}
	if (comp[k] >= 0 && t + 1 < comp[k] + ttc + cd)
		fail(ctx "cooldown violated: the dongle shared with coder " k " is usable from " (comp[k] + ttc + cd) \
			" (its compile at " comp[k] " + " ttc " + cooldown " cd "), expected this start at " \
			(comp[k] + ttc + cd) " or later, got " t, "cooldown")
}

function on_compile(t, x,    gap, k, par) {
	if (state[x] != "taking" || takes[x] != 2)
		fail(ctx "compile without dongles: expected two \"has taken a dongle\" lines first, got " takes[x], "order")
	if (done_t >= 0 && !late_warned && t > done_t + ttc + ptol) {
		late_warned = 1
		warn(ctx "compile started after every coder had completed " req \
			" compiles (by about " (done_t + ttc) " ms): the simulation should have stopped")
	}
	gap = t - last[x]
	if (gap > ttb + slack) {
		late_starts++
		if (gap > late_gap)
			late_gap = gap
	}
	if (gap > ttb + slack)
		fail(ctx "started compiling " gap " ms after its previous compile start: expected a burnout at " \
			(last[x] + ttb) " (last start " last[x] " + " ttb "), got a compile start at " t, "late_start")
	check_dongle(t, x, x)
	check_dongle(t, x, left(x))
	if (right(x) != left(x))
		check_dongle(t, x, right(x))
	# Holding one dongle much longer than a neighbour's compile and cooldown
	# while waiting for the second one: hold and wait.
	if (takes[x] == 2 && t - take1[x] > ttc + cd + ptol) {
		holds++
		if (t - take1[x] > hold_max) {
			hold_max = t - take1[x]
			hold_x = x
			hold_from = take1[x]
			hold_to = t
		}
	}
	par = 1
	for (k = 1; k <= n; k++)
		if (k != x && state[k] == "compiling" && t < comp[k] + ttc)
			par++
	if (par > maxpar)
		maxpar = par
	ncomp++
	ct[ncomp] = t
	cx[ncomp] = x
	if (count[x] == 0)
		first[x] = t
	state[x] = "compiling"
	takes[x] = 0
	comp[x] = t
	last[x] = t
	count[x]++
	if (req > 0 && count[x] == req && ++reached == n)
		done_t = t
}

function on_debug(t, x,    d) {
	if (state[x] != "compiling")
		fail(ctx "debugging without compiling first: expected \"is compiling\" before it, got state " state[x], "order")
	else {
		d = t - comp[x]
		if (d + 1 < ttc)
			fail(ctx "compiling too short: expected at least " ttc " ms (time_to_compile), got " d " ms", "short")
		else if (d > ttc + ptol)
			warn(ctx "compiling lasted " d " ms (time_to_compile = " ttc ")")
	}
	state[x] = "debugging"
	mark[x] = t
}

function on_refactor(t, x,    d) {
	if (state[x] != "debugging")
		fail(ctx "refactoring without debugging first: expected \"is debugging\" before it, got state " state[x], "order")
	else {
		d = t - mark[x]
		if (d + 1 < ttd)
			fail(ctx "debugging too short: expected at least " ttd " ms (time_to_debug), got " d " ms", "short")
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
		fail(ctx "burnout too early: expected at " (last[x] + ttb) " or later (last start " last[x] " + " ttb "), got " t, "early_burnout")
	else if (d > ttb + 10 + slack) {
		fail(ctx "burnout printed " (d - ttb) " ms after the deadline: expected by " (last[x] + ttb + 10) \
			" (deadline " (last[x] + ttb) " + 10 ms), got " t, "late_burnout")
		if (ttc > 10 + slack && d - ttb >= ttc - 10 - slack && d - ttb <= ttc + 10 + slack)
			end_base = 1
	}
	# Another coder whose deadline came earlier should have been reported first.
	for (i = 1; i <= n; i++)
		if (i != x && last[i] + slack < last[x] && t - last[i] > ttb + 10 + slack)
			fail(ctx "coder " i "'s deadline (" (last[i] + ttb) ") came before coder " x "'s (" (last[x] + ttb) \
				"), so coder " i " should have been reported", "missed_burnout")
}

{
	ctx = "line " NR " \"" $0 "\": "
	if (burned) {
		fail(ctx "printed after the burnout at " burn_t ": expected no more output", "after")
		next
	}
	if ($0 !~ /^[0-9]+ [0-9]+ (has taken a dongle|is compiling|is debugging|is refactoring|burned out)$/) {
		fail(ctx "does not match the log format: expected \"<ms> <coder> has taken a dongle|is compiling|is debugging|is refactoring|burned out\"", "format")
		next
	}
	t = $1 + 0
	x = $2 + 0
	if (x < 1 || x > n) {
		fail(ctx "coder number: expected 1.." n ", got " x, "format")
		next
	}
	if (NR <= 200000) {
		text[NR] = $0
		who[NR] = x
	}
	if (t < prev)
		fail(ctx "timestamp goes backwards: expected " prev " or later, got " t, "backwards")
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

# Best possible time between two compile starts of one coder, ignoring OS
# delays: its own phases (and the cooldown of its own dongles), and the
# dongle sharing: at most floor(n/2) coders compile at once, and each
# compile occupies its dongles for ttc + cd.
function best_cycle(    own, share, rest) {
	if (n == 1)
		return -1
	rest = ttd + ttr
	own = ttc + (rest > cd ? rest : cd)
	share = n * (ttc + cd) / int(n / 2)
	share = int(share) + (share > int(share))
	return (own > share ? own : share)
}

function share_need(    v) {
	v = n * (ttc + cd) / int(n / 2)
	return int(v) + (v > int(v))
}

function feasibility(    p) {
	p = best_cycle()
	if (p < 0)
		diag("one coder has one dongle and can never compile: a burnout at " ttb " ms is the only correct outcome")
	else if (p < ttb)
		diag("feasibility: the best possible cycle is about " p " ms (own phases need " \
			(ttc + (ttd + ttr > cd ? ttd + ttr : cd)) " ms, sharing dongles with " int(n / 2) \
			" compiling at once needs " share_need() " ms) against time_to_burnout " ttb \
			" ms, so a schedule without burnout exists with " (ttb - p) " ms of margin")
	else if (expect == "burnout")
		diag("feasibility: the best possible cycle is about " p " ms, not shorter than time_to_burnout " ttb \
			" ms, so a burnout must happen, as this case expects")
	else
		diag("feasibility: the best possible cycle is about " p " ms, not shorter than time_to_burnout " ttb \
			" ms, so a burnout is expected; the case expectation may be wrong")
	return p
}

function nb_starts(k, from, to,    j, out, c) {
	out = ""
	c = 0
	for (j = 1; j <= ncomp; j++)
		if (cx[j] == k && ct[j] >= from && ct[j] <= to) {
			c++
			if (c <= 4)
				out = out (c > 1 ? ", " : "") ct[j]
		}
	if (c > 4)
		out = out ", ..."
	return c (c ? " time" (c > 1 ? "s" : "") " (at " out ")" : " times")
}

function explain_burnout(x, t,    p, ready, l, r, starts, i, shown, from, line) {
	p = feasibility()
	l = left(x)
	r = right(x)
	diag("coder " x ": last compile start " last[x] " (" (count[x] ? "compile #" count[x] : "simulation start") \
		"), deadline " (last[x] + ttb) ", burned out at " t)
	if (state[x] == "taking" || state[x] == "start" || state[x] == "refactoring") {
		ready = (count[x] ? last[x] + ttc + ttd + ttr : 0)
		if (state[x] == "refactoring")
			ready = mark[x] + ttr
		if (state[x] == "taking")
			diag("coder " x " was waiting for dongles: ready from about " ready ", took " takes[x] \
				" of 2 (first at " take1[x] ")")
		else if (state[x] == "refactoring" && t < ready)
			diag("coder " x " was still refactoring until " ready ": compile + debug + refactor (" \
				(ttc + ttd + ttr) " ms) plus its wait for dongles did not fit in time_to_burnout")
		else
			diag("coder " x " was waiting for dongles since about " ready " and had not taken any")
		starts = 0
		if (n > 1) {
			diag("while it waited (" ready "-" t "), left neighbour " l " compiled " nb_starts(l, ready, t) \
				(r != l ? ", right neighbour " r " compiled " nb_starts(r, ready, t) : ""))
			for (i = 1; i <= ncomp; i++)
				if ((cx[i] == l || cx[i] == r) && ct[i] >= ready && ct[i] <= t)
					starts++
		}
		if (state[x] == "taking" && takes[x] == 1 && t - take1[x] > ttc + cd + ptol) {
			holds++
			if (t - take1[x] > hold_max) {
				hold_max = t - take1[x]
				hold_x = x
				hold_from = take1[x]
				hold_to = t
			}
		}
		if (holds == 0 && starts >= 2 && p > 0 && p < ttb)
			print "HINT: its neighbours compiled " starts " times while it waited. Either the arbitration did not serve it first (under edf it had the earliest deadline, under fifo the oldest request), or it had not requested that dongle yet because it was stuck waiting for its other one. Check that requests are queued when they are made, ordered by the scheduler's key, and that a coder takes a dongle only at the head of its queue."
	} else if (state[x] == "compiling")
		diag("coder " x " was compiling: time_to_compile " ttc " ms is not shorter than time_to_burnout " ttb " ms")
	else
		diag("coder " x " was " state[x] ": its deadline expired before it could request dongles again " \
			"(compile + debug + refactor = " (ttc + ttd + ttr) " ms)")
	if (holds > 0) {
		if (starts >= 2)
			diag("its neighbours compiled " starts " times while it waited; it could not compete for their dongles while stuck behind the hold and wait below")
		diag("hold and wait: coder " hold_x " took one dongle at " hold_from " and got the second only at " \
			hold_to " (" hold_max " ms later)" (holds > 1 ? "; " holds " such waits in this run" : "") \
			". Meanwhile that dongle was useless to its other neighbour.")
		print "HINT: a coder that holds one dongle while waiting for the other blocks a neighbour, who may block the next one: coders then compile one after another (a staircase) instead of in parallel. Ways out: odd and even coders take their dongles in opposite order; or take both dongles together, only when both are free and you lead both queues; and never sit on one dongle you cannot use yet."
	} else if (n >= 4 && maxpar == 1 && ncomp >= 3) {
		line = ""
		shown = 0
		for (i = 1; i <= n && shown < 8; i++)
			if (count[i] > 0) {
				line = line (shown ? ", " : "") "coder " i "@" first[i]
				shown++
			}
		diag("never more than one coder compiled at a time, although up to " int(n / 2) " can; first compile starts: " line)
		print "HINT: coders compiled one after another (a staircase) instead of in parallel. This happens when a coder waits for a queue head that is itself waiting for another dongle. Let a coder whose two dongles are both free and who leads both queues go ahead, or have odd and even coders take their dongles in opposite order."
	}
	if (maxpar > 0)
		diag("at most " maxpar " coder" (maxpar > 1 ? "s" : "") " compiled at the same time (up to " int(n / 2) " possible)")
	if (p > 0 && p < ttb)
		print "HINT: the timings are feasible, so this burnout comes from the implementation, not from the parameters. Subject v1.5 requires liveness under edf for feasible parameters; under fifo it promises nothing, but timings with this much margin should still be met. Read the timeline below; the full output is in the case's .out file."
	from = NR - 400
	if (from < 1)
		from = 1
	shown = 0
	for (i = NR; i >= from && shown < 10; i--)
		if (i in who && (who[i] == x || who[i] == l || who[i] == r))
			keep[++shown] = text[i]
	if (shown) {
		diag("last lines of coders " (n > 2 ? l ", " x ", " r : (n == 2 ? "1, 2" : x)) ":")
		for (i = shown; i >= 1; i--)
			diag("  " keep[i])
	}
}

END {
	if (config_bad) exit 2
	ctx = "end of log: "
	if (NR == 0)
		fail(ctx "no output at all: expected simulation log lines", "no_output")
	if (aborted && !burned) {
		# The run crashed or was stopped: the log just ends, and its
		# completeness was already reported by the runner.
		if (done_t >= 0)
			diag("every coder had completed " req " compiles by about " (done_t + ttc) " ms, but the program kept running until it was stopped at " prev " ms: the completion check never ended the simulation")
	} else if (expect == "survive" || (expect == "any" && !burned)) {
		if (burned) {
			fail(ctx "unexpected burnout of coder " burn_x " at " burn_t " ms: expected every coder to reach " req " compiles without a burnout")
			explain_burnout(burn_x, burn_t)
		} else {
			for (i = 1; i <= n; i++) {
				completed = count[i]
				if (state[i] == "compiling" && prev + 1 < comp[i] + ttc)
					completed--
				if (count[i] < req)
					fail(ctx "coder " i " started only " count[i] " compiles: expected at least " req, "count")
				else if (completed < req)
					warn(ctx "final compile completion for coder " i " is not visible; logs alone cannot confirm completion")
				if (prev - last[i] > ttb + 10 + slack)
					fail(ctx "coder " i " passed its deadline at " (last[i] + ttb) " without a burnout: expected a burnout line by " (last[i] + ttb + 10), "missed_burnout")
			}
		}
	}
	if (late_starts && (late_gap <= ttb + ttc + 10 + slack) && ttc > 10 + slack)
		end_base = 1
	if (end_base) {
		diag("the delays match time_to_compile (" ttc " ms): the deadline looks counted from the END of a compile")
		print "HINT: burnout counts from the START of the last compile: set last_compile_start when \"is compiling\" is logged, not after the compile sleep, and do not update it again when the compile ends."
	}
	if (expect == "burnout" && !burned && NR > 0) {
		fail(ctx "expected a burnout, but none was printed: got " (prev >= 0 ? "a log ending at " prev " ms" : "no log"), "no_burnout")
		feasibility()
	}
	lo = -1
	hi = 0
	for (i = 1; i <= n; i++) {
		if (lo < 0 || count[i] < lo)
			lo = count[i]
		if (count[i] > hi)
			hi = count[i]
	}
	if (burned)
		print "GOT: coder " burn_x " burned out at " burn_t " ms; compile starts per coder " lo "-" hi
	else if (NR > 0)
		print "GOT: no burnout; log ends at " prev " ms; compile starts per coder " lo "-" hi \
			(req > 0 ? " (" req " required)" : "")
	else
		print "GOT: no output"
	print "INFO: " NR " lines, compile starts per coder: min " lo ", max " hi \
		(burned ? ", coder " burn_x " burned out at " burn_t : "")
	exit (fails > 0)
}
