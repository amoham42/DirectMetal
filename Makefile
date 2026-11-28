SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

SUBSYSTEMS := \
	runtime/dm_sync \
	runtime/dm_prefix \
	sandbox/dm_sandbox \
	runtime/dm_host_io \
	shaders/dm_shader_cache \
	sandbox/dm_attestation \
	graphics/dm_metal_core \
	upscaling/dm_metalfx_bridge

COMMON_ROOT := $(shell c="$$(git rev-parse --git-common-dir 2>/dev/null)"; if [ -n "$$c" ]; then cd "$$c/.." 2>/dev/null && pwd; fi)
PYTHON := $(shell if [ -x .venv/bin/python ]; then echo .venv/bin/python; elif [ -n "$(COMMON_ROOT)" ] && [ -x "$(COMMON_ROOT)/.venv/bin/python" ]; then echo "$(COMMON_ROOT)/.venv/bin/python"; else echo python3; fi)

.PHONY: help lint test ci build-subsystems app app-lite dmg dmg-lite dmg-ultra conformance phase4 clean

help: ## Show available DirectMetal build, test, and packaging targets
	@printf "DirectMetal — Apple Silicon DirectX Runtime Build System\n\n"
	@printf "Usage:\n  make <target>\n\nTargets:\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Validate shell scripts, Python tools, JSON configs, and workflow YAMLs
	@echo "[lint] Checking shell script syntax (bash -n)..."
	@bash -n scripts/*.sh
	@echo "[lint] Checking Python syntax (py_compile)..."
	@python3 -m py_compile scripts/*.py tools/*.py
	@echo "[lint] Checking JSON files in runtime/, graphics/, and tests/reference/..."
	@python3 -c 'import json, pathlib, sys; roots = [pathlib.Path(p) for p in ("runtime", "graphics", "tests/reference") if pathlib.Path(p).exists()]; files = sorted(f for r in roots for f in r.rglob("*.json")); [json.loads(f.read_text(encoding="utf-8")) for f in files]; print(f"  Validated {len(files)} JSON file(s).")'
	@if [ -d .github/workflows ]; then \
		echo "[lint] Checking GitHub Actions workflow YAML files..."; \
		if python3 -c "import yaml" >/dev/null 2>&1; then \
			python3 -c 'import pathlib, yaml; files = sorted(pathlib.Path(".github/workflows").glob("*.yml")); [yaml.safe_load(f.read_text(encoding="utf-8")) for f in files]; print(f"  Validated {len(files)} workflow file(s) via PyYAML.")'; \
		elif command -v ruby >/dev/null 2>&1; then \
			ruby -ryaml -rdate -e 'ARGV.each { |f| YAML.safe_load(File.read(f), permitted_classes: [Date, Time]) }; puts "  Validated #{ARGV.size} workflow file(s) via Ruby Psych."' .github/workflows/*.yml; \
		fi; \
	fi
	@echo "[lint] All static checks passed."

build-subsystems: ## Build all native C/Obj-C++ CMake subsystems under build/
	@set -e; \
	for sub in $(SUBSYSTEMS); do \
		name="$$(basename "$$sub")"; \
		echo "[cmake] Building $$name..."; \
		cmake -S "$$sub" -B "build/$$name" >/dev/null; \
		cmake --build "build/$$name" -j >/dev/null; \
	done
	@echo "[cmake] Built all $$(printf '%s\n' $(SUBSYSTEMS) | wc -w | tr -d ' ') CMake subsystems."

test: build-subsystems ## Run Python diff-harness unit tests and C/Obj-C++ subsystem tests
	@echo "[test] Running Python diff harness unit tests..."
	@if $(PYTHON) -c "import PIL, numpy" >/dev/null 2>&1; then \
		PYTHONPATH=tools $(PYTHON) tools/test_diff_harness.py; \
	else \
		echo "error: Pillow and NumPy are required for tools/test_diff_harness.py (install in .venv or pip install pillow numpy)" >&2; \
		exit 1; \
	fi
	@echo "[test] Running C/Obj-C++ host subsystem tests..."
	@./build/dm_sync/dm_sync_test
	@./build/dm_prefix/dm_prefix_test
	@mkdir -p "$$HOME/.ssh"
	@./build/dm_sandbox/dm_sandbox_test sandbox/profiles/directmetal_game.sb.tmpl
	@./build/dm_host_io/dm_host_io_test
	@if swift -e 'import Metal; guard let d = MTLCreateSystemDefaultDevice(), !d.name.lowercased().contains("paravirtual") else { exit(1) }' >/dev/null 2>&1; then \
		./build/dm_shader_cache/dm_shader_cache_test; \
	else \
		echo "[test] Skipping dm_shader_cache_test (no hardware Metal GPU device available)."; \
	fi
	@if csrutil status 2>/dev/null | grep -q "enabled" && csrutil authenticated-root status 2>/dev/null | grep -q "enabled"; then \
		./build/dm_attestation/dm_attestation_test; \
	else \
		echo "[test] Skipping dm_attestation_test live SIP/SSV assertion (host VM has SIP/SSV disabled)."; \
	fi

ci: ## Run the full local CI verification suite (scripts/run_ci_local.sh)
	@./scripts/run_ci_local.sh

app: ## Build offline DirectMetal.app bundle in dist/DirectMetal.app
	@./scripts/package_app.sh

app-lite: ## Build compact DirectMetal-Lite.app (~2.3-2.9 MB) in dist/DirectMetal-Lite.app
	@./scripts/package_app.sh --lite

dmg: ## Build compressed ULFO offline DMG + SHA-256 in dist/DirectMetal-macOS-arm64.dmg
	@./scripts/build_dmg.sh --repackage

dmg-lite: ## Build compact DirectMetal-Lite DMG + SHA-256 in dist/DirectMetal-Lite-macOS-arm64.dmg
	@./scripts/build_dmg.sh --lite --repackage

dmg-ultra: ## Build max-compression ULMO (LZMA) offline DMG + SHA-256 in dist/
	@./scripts/build_dmg.sh --ultra-compress --repackage

conformance: ## Run D3D11/D3D12/Engine conformance suite + RTX 3070 PSNR/SSIM diff
	@./scripts/run_conformance_macos.sh

phase4: ## Run Phase 4 Seatbelt sandbox, Secure Enclave attestation, and SM 6.0 engine suite
	@./scripts/run_phase4_verify.sh

clean: ## Remove build/, dist/, out/, and temporary Python bytecode caches
	@rm -rf build dist out
	@find . -maxdepth 3 -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -maxdepth 3 -name "*.pyc" -type f -delete 2>/dev/null || true
	@echo "[clean] Removed build/, dist/, out/, and __pycache__."
