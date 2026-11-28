# LEN5 system-level simulator
ROOT_DIR := $(abspath ..)
BUILD_DIR ?= $(ROOT_DIR)/build
PYTHON ?= $(if $(wildcard $(CURDIR)/system_level/.venv/bin/python),$(CURDIR)/system_level/.venv/bin/python,python3)
CONFIG ?= python/system_level/config.yaml
SIM_PROJECT ?= $(PROJECT)
SIM_JOBS ?= $(JOBS)
SUITE ?= embench
SPIKE ?= spike
SPIKE_TIMEOUT ?= 300
RISCV_EXE_PREFIX ?= riscv64-unknown-elf

# Resolve command-line paths from the checkout root, as in the software targets.
root_path = $(if $(filter /%,$(1)),$(1),$(ROOT_DIR)/$(1))
quote = '$(subst ','"'"',$(1))'
CLI = PYTHONPATH="$(CURDIR)$${PYTHONPATH:+:$$PYTHONPATH}" "$(PYTHON)" -m system_level
BUILD_OPTION = --build-dir $(call quote,$(call root_path,$(BUILD_DIR)))
REPORT_OPTIONS = $(if $(PLOT_PRESET),--plot-preset $(call quote,$(PLOT_PRESET))) \
	$(if $(VERBOSITY),--verbosity $(call quote,$(VERBOSITY)))
RUN_OPTIONS = --config $(call quote,$(call root_path,$(CONFIG))) \
	$(REPORT_OPTIONS) \
	$(if $(RUN_NAME),--name $(call quote,$(RUN_NAME))) \
	$(if $(OUTPUT),--output $(call quote,$(call root_path,$(OUTPUT)))) \
	$(if $(SEEDS),--make-seeds $(call quote,$(SEEDS))) \
	$(if $(INSTRUCTIONS),--instructions $(call quote,$(INSTRUCTIONS))) \
	$(if $(SMT),--smt $(call quote,$(SMT))) \
	$(if $(SIM_JOBS),--jobs $(call quote,$(SIM_JOBS))) \
	$(if $(filter 1 true,$(NO_PLOTS)),--no-plots)
SPIKE_OPTIONS = --spike $(call quote,$(SPIKE)) --spike-timeout $(call quote,$(SPIKE_TIMEOUT)) \
	--riscv-prefix $(call quote,$(RISCV_EXE_PREFIX)) --make $(call quote,$(MAKE))

.PHONY: sim-run sim-run-benchmarks sim-plots sim-sweep sim-test
.PHONY: sim-list-benchmarks sim-help sim-clean-results

sim-run:
	$(CLI) simulate $(BUILD_OPTION) $(RUN_OPTIONS) $(SPIKE_OPTIONS) $(if $(SIM_PROJECT),--project $(call quote,$(SIM_PROJECT)))

sim-run-benchmarks:
	$(CLI) benchmarks $(BUILD_OPTION) $(RUN_OPTIONS) $(SPIKE_OPTIONS) --suite $(call quote,$(SUITE)) \
		$(if $(PAIR_MODE),--pair-mode $(call quote,$(PAIR_MODE))) \
		$(if $(BENCHMARK_PAIRS),--benchmark-pairs $(call quote,$(BENCHMARK_PAIRS))) \
		$(if $(BENCHMARKS),--benchmarks $(call quote,$(BENCHMARKS)),$(if $(BENCHMARK),--benchmarks $(call quote,$(BENCHMARK))))

sim-plots:
	$(CLI) report $(BUILD_OPTION) $(REPORT_OPTIONS) $(if $(INPUT),--input $(call quote,$(call root_path,$(INPUT)))) \
		$(if $(OUTPUT),--output $(call quote,$(call root_path,$(OUTPUT))))

sim-sweep:
	$(CLI) $(if $(or $(PRESET),$(SWEEP)),sweep,suite) $(BUILD_OPTION) $(RUN_OPTIONS) \
		$(if $(PRESET),--preset $(call quote,$(PRESET))) $(if $(SWEEP),--sweep $(call quote,$(SWEEP)))

sim-list-benchmarks:
	$(CLI) list-benchmarks --suite $(call quote,$(SUITE))

sim-test:
	PYTHONPATH="$(CURDIR)$${PYTHONPATH:+:$$PYTHONPATH}" "$(PYTHON)" -m unittest discover -s system_level/tests -v

sim-help:
	@printf '%s\n' \
		'sim-run                Run and plot the configured workload or a Spike PROJECT.' \
		'sim-run-benchmarks     Build with SPIKE_CHECK, run Spike, and compare benchmarks.' \
		'sim-plots              Regenerate plots from INPUT or all completed runs.' \
		'sim-sweep              Run the sweep suite or select PRESET / SWEEP.' \
		'sim-list-benchmarks    List installed benchmarks for SUITE.' \
		'sim-test               Run the simulator tests.' \
		'sim-clean-results      Remove only BUILD_DIR/simulation.' \
		'Options: CONFIG, BUILD_DIR, RUN_NAME, OUTPUT, SEEDS (count or list), INSTRUCTIONS, SMT, JOBS, NO_PLOTS.' \
		'Spike options: PROJECT, SUITE, BENCHMARK, BENCHMARKS, SPIKE, SPIKE_TIMEOUT, RISCV_EXE_PREFIX.' \
		'SMT benchmark pairs: PAIR_MODE=same (default), all (unordered), or ordered (full matrix).' \
		'BENCHMARK_PAIRS overrides the pair list. PLOT_PRESET=essential|detailed|none. VERBOSITY=quiet|normal|verbose.' \
		'Frontend: CONFIG=python/system_level/config/frontend.yaml, or architectures like basic_block_ooo_commit@tage.' \
		'Frontend sweeps: PRESET=frontend-predictor|fetch-fifo|issue-queue|btq-capacity|ras-depth.' \
		'Example: make sim-run-benchmarks BENCHMARKS="crc32 matmult-int" SEEDS=30'

sim-clean-results:
	$(CLI) clean $(BUILD_OPTION)
