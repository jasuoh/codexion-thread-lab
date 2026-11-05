# Codexion test lab. Point CODEXION at your binary and CODEXION_SRC at its
# project directory, e.g.:
#   make check CODEXION=../codexion/coders/codexion CODEXION_SRC=../codexion/coders
# Without CODEXION, the runner builds and tests coders/ in this checkout.
# Extra runner options can be passed with ARGS, e.g. make check ARGS=edf.

RUNNER  := tests/run_tests.sh
PY      := PYTHONDONTWRITEBYTECODE=1 python3
REPEAT  ?= 10
ARGS    ?=

# Pass settings through to the runner only when they are set.
export CODEXION CODEXION_SRC CODEXION_LOGDIR CASES TIME_LIMIT SLACK PHASE_TOL \
	CPU_WARN LATENCY_WARN RACE_TOOL RACE_MAX_CODERS

.DEFAULT_GOAL := help
.PHONY: help test check stress leaks races repeat full tui functions build-check \
	logs latest clean

help:
	@echo 'Self-tests (no Codexion binary needed)'
	@echo '  make test          check the checker, runner and menu'
	@echo
	@echo 'Testing an implementation (set CODEXION=path, optionally CODEXION_SRC=dir)'
	@echo '  make check         baseline cases, function check, Makefile/Norm check'
	@echo '  make stress        baseline plus timing and many-thread experiments'
	@echo '  make leaks         baseline plus Valgrind memcheck on small cases'
	@echo '  make races         baseline plus Valgrind DRD race detection on small cases'
	@echo '  make repeat        baseline cases REPEAT times (default 10)'
	@echo '  make full          stress, leaks and races together'
	@echo '  make tui           interactive case selector'
	@echo '  make functions     only the allowed-function/global check (binary or CODEXION_SRC)'
	@echo '  make build-check   only the Makefile/Norm check of CODEXION_SRC'
	@echo
	@echo 'Logs'
	@echo '  make logs          list saved runs with their result line'
	@echo '  make latest        show the summary and run.info of the newest run'
	@echo '  make clean         delete tests/logs and Python caches (preview: make -n clean)'

test:
	$(PY) tests/self_test.py

check:
	$(RUNNER) --batch $(ARGS)

stress:
	$(RUNNER) --batch --stress $(ARGS)

leaks:
	$(RUNNER) --batch --leaks $(ARGS)

races:
	$(RUNNER) --batch --races $(ARGS)

repeat:
	$(RUNNER) --batch --repeat $(REPEAT) $(ARGS)

full:
	$(RUNNER) --batch --stress --leaks --races $(ARGS)

tui:
	$(RUNNER) --tui $(ARGS)

functions:
	@target="$${CODEXION_SRC:-$${CODEXION:-coders/codexion}}"; \
	echo "checking $$target"; $(PY) tests/check_functions.py "$$target"

build-check:
	@[ -n "$$CODEXION_SRC" ] || { echo 'Set CODEXION_SRC=path/to/project'; exit 2; }
	tests/check_build.sh "$$CODEXION_SRC"

logs:
	@dir="$${CODEXION_LOGDIR:-tests/logs}"; \
	for run in $$(ls -d "$$dir"/run-* 2>/dev/null | sort); do \
		printf '%-34s %s\n' "$$(basename "$$run")" \
			"$$(grep -h '^passed:' "$$run/summary.txt" 2>/dev/null || echo '(incomplete)')"; \
	done

latest:
	@dir="$${CODEXION_LOGDIR:-tests/logs}/latest"; \
	[ -d "$$dir" ] || { echo "No runs in $${CODEXION_LOGDIR:-tests/logs}"; exit 1; }; \
	cat "$$dir/run.info"; echo; cat "$$dir/summary.txt"

clean:
	rm -rf -- tests/logs tests/__pycache__
