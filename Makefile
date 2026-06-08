.PHONY: help package package-lite clean

VERSION := $(shell awk -F= '$$1=="version"{print $$2; exit}' module.prop)

help:
	@printf 'Flux build targets:\n'
	@printf '  make package        Build full module zip (binaries included)\n'
	@printf '  make package-lite   Build lite zip (user supplies binaries)\n'
	@printf '  make clean          Remove dist/\n'
	@printf '\nVersion: %s\n' '$(VERSION)'

package:
	@bash tools/package.sh

package-lite:
	@bash tools/package.sh --lite

clean:
	@rm -rf dist/
