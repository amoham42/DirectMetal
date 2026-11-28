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

.PHONY: help lint validate-profiles test test-python test-swift ctest ci build-subsystems app app-lite dmg dmg-lite dmg-ultra conformance phase4 clean

help: ## Show available DirectMetal build, test, and packaging targets
	@printf "DirectMetal — Apple Silicon DirectX Runtime Build System\n\n"
	@printf "Usage:\n  make <target>\n\nTargets:\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Validate shell scripts, Python tools, JSON configs, profiles, and workflow YAMLs
	@echo "[lint] Checking shell script syntax (bash -n)..."
	@bash -n scripts/*.sh
	@echo "[lint] Checking Python syntax (py_compile)..."
	@python3 -m py_compile scripts/*.py tools/*.py
	@echo "[lint] Checking JSON files in runtime/, graphics/, and tests/reference/..."
	@python3 -c 'import json, pathlib, sys; roots = [pathlib.Path(p) for p in ("runtime", "graphics", "tests/reference") if pathlib.Path(p).exists()]; files = sorted(f for r in roots for f in r.rglob("*.json")); [json.loads(f.read_text(encoding="utf-8")) for f in files]; print(f"  Validated {len(files)} JSON file(s).")'
	@if [ -f scripts/validate_profiles.py ]; then \
		echo "[lint] Validating game profiles schema (scripts/validate_profiles.py)..."; \
		python3 scripts/validate_profiles.py; \
	fi
	@echo "[lint] Checking Vulkan compat layer strict C warnings (-Wall -Wextra -Werror)..."
	@xcrun clang -fsyntax-only -O3 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -fvisibility=hidden graphics/dm_vk_compat/dm_vk_compat_layer.c
	@if [ -d .github/workflows ]; then \
		echo "[lint] Checking GitHub Actions workflow YAML files..."; \
		if python3 -c "import yaml" >/dev/null 2>&1; then \
			python3 -c 'import pathlib, yaml; files = sorted(pathlib.Path(".github/workflows").glob("*.yml")); [yaml.safe_load(f.read_text(encoding="utf-8")) for f in files]; print(f"  Validated {len(files)} workflow file(s) via PyYAML.")'; \
		elif command -v ruby >/dev/null 2>&1; then \
			ruby -ryaml -rdate -e 'ARGV.each { |f| YAML.safe_load(File.read(f), permitted_classes: [Date, Time]) }; puts "  Validated #{ARGV.size} workflow file(s) via Ruby Psych."' .github/workflows/*.yml; \
		fi; \
	fi
	@echo "[lint] All static checks passed."

validate-profiles: ## Validate runtime/profiles/game_profiles.json schema
	@if [ -f scripts/validate_profiles.py ]; then \
		echo "[profiles] Running scripts/validate_profiles.py..."; \
		python3 scripts/validate_profiles.py; \
	else \
		echo "[profiles] scripts/validate_profiles.py not present; verifying game_profiles.json syntax..."; \
		python3 -c 'import json, pathlib; p = pathlib.Path("runtime/profiles/game_profiles.json"); data = json.loads(p.read_text(encoding="utf-8")); assert isinstance(data, (dict, list)); print(f"  [OK] {p} is valid JSON.")'; \
	fi

build-subsystems: ## Build all native C/Obj-C++ CMake subsystems under build/
	@set -e; \
	for sub in $(SUBSYSTEMS); do \
		name="$$(basename "$$sub")"; \
		echo "[cmake] Building $$name..."; \
		cmake -S "$$sub" -B "build/$$name" >/dev/null; \
		cmake --build "build/$$name" -j >/dev/null; \
	done
	@echo "[cmake] Built all $$(printf '%s\n' $(SUBSYSTEMS) | wc -w | tr -d ' ') CMake subsystems."

test-swift: ## Compile and run Swift unit tests (tests/swift/DirectMetalTests.swift)
	@set -euo pipefail; \
	if [ -f tests/swift/DirectMetalTests.swift ]; then \
		echo "[test-swift] Compiling & running tests/swift/DirectMetalTests.swift..."; \
		mkdir -p build/swift_tests; \
		lib_srcs=(); \
		for sf in app/DirectMetalApp/*.swift; do \
			[ "$$(basename "$$sf")" = "main.swift" ] && continue; \
			lib_srcs+=("$$sf"); \
		done; \
		extra_tests=(); \
		for tf in tests/swift/*.swift; do \
			[ "$$(basename "$$tf")" = "DirectMetalTests.swift" ] && continue; \
			extra_tests+=("$$tf"); \
		done; \
		entry="tests/swift/DirectMetalTests.swift"; \
		if ! grep -Eq '^[[:space:]]*@main\b' "$$entry"; then \
			cp "$$entry" build/swift_tests/main.swift; \
			entry="build/swift_tests/main.swift"; \
		fi; \
		xcrun swiftc \
			-warnings-as-errors \
			-target arm64-apple-macos15.0 \
			-framework SwiftUI \
			-framework AppKit \
			-framework CoreGraphics \
			-framework Metal \
			-framework MetalFX \
			-framework GameController \
			-framework CryptoKit \
			-framework Security \
			-framework DeviceCheck \
			-framework UniformTypeIdentifiers \
			"$${lib_srcs[@]}" \
			$${extra_tests[@]+"$${extra_tests[@]}"} \
			"$$entry" \
			-o build/swift_tests/DirectMetalTests; \
		./build/swift_tests/DirectMetalTests; \
	else \
		echo "[test-swift] tests/swift/DirectMetalTests.swift not present; typechecking DirectMetalApp Swift sources..."; \
		xcrun swiftc -typecheck \
			-target arm64-apple-macos15.0 \
			-framework SwiftUI \
			-framework AppKit \
			-framework CoreGraphics \
			-framework Metal \
			-framework MetalFX \
			-framework GameController \
			-framework CryptoKit \
			-framework Security \
			-framework DeviceCheck \
			-framework UniformTypeIdentifiers \
			app/DirectMetalApp/*.swift; \
		echo "[test-swift] DirectMetalApp Swift typecheck passed."; \
	fi

test-python: ## Run Python packaging, deduplication, dehydration & profile unit tests
	@if [ -d tests/python ]; then \
		echo "[test-python] Running tests/python unittest suite..."; \
		python3 -m unittest discover -s tests/python -v; \
	fi

ctest: ## Build and run all 10 native C/Obj-C++ subsystem tests via root CMake superbuild
	@cmake -S . -B build/superbuild -DCMAKE_BUILD_TYPE=Release
	@cmake --build build/superbuild -j
	@ctest --test-dir build/superbuild --output-on-failure

test: build-subsystems test-python ## Run Python, C/Obj-C++ subsystem, and Swift unit tests
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
	@./build/dm_attestation/dm_attestation_test
	@if [ -f tests/swift/DirectMetalTests.swift ]; then \
		$(MAKE) --no-print-directory test-swift; \
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
