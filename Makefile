.PHONY: help test clean

help:
	@echo 'make test     Run the test-lab self-tests (no Codexion binary needed)'
	@echo 'make clean    Remove local test logs and Python caches'
	@echo 'make -n clean Preview cleanup without deleting anything'

test:
	PYTHONDONTWRITEBYTECODE=1 python3 tests/self_test.py

clean:
	rm -rf -- tests/logs tests/__pycache__
