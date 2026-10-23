####################
# ----- INFO ----- #
####################
# Makefile to generate the LEN5 processor files and build the design with fusesoc

#############################
# ----- CONFIGURATION ----- #
#############################

# General configuration
MAKE           	?= make
BUILD_DIR	   	?= $(realpath .)/build

# Software build configuration
PROJECT  		?= hello_world
SUITE   		?= embench
BENCHMARK 		?= crc32
LINKER   		?= $(realpath sw/linker/len5-sim.ld)
COPT   	 		?= -O2
SOFTWARE_DIR    ?= $(BUILD_DIR)

# RTL simulation
FIRMWARE		?= $(BUILD_DIR)/main.hex
MAX_CYCLES		?= 100000
LOG_LEVEL		?= LOG_MEDIUM
VERBOSE         ?= false
FUSESOC         ?= fusesoc
VERILATOR       ?= verilator
JOBS            ?= 4

# Debug simulation (RTL checked against Spike)
DEBUG_BUILD_DIR ?= $(BUILD_DIR)/debug
DEBUG_SUITE_DIR ?= $(BUILD_DIR)/$(SUITE)_debug
DEBUG_ARGS      ?=
SIM_RUN_DIR     ?= $(abspath $(BUILD_DIR)/sim-common)
SPIKE_SRC       ?= $(abspath sw/vendor/riscv-isa-sim)
SPIKE_BUILD     ?= $(BUILD_DIR)/spike-build

#Waveform font size
FONT_SIZE       ?= 14

# Regression tests
TEST_DIRS		:= $(wildcard sw/applications/*/)
TESTS			:= $(patsubst sw/applications/%/,%,$(TEST_DIRS))
TESTS_EXCLUDE	:= timer alu_mult alu_div #TODO fix
TESTS			:= $(filter-out $(TESTS_EXCLUDE),$(TESTS))

# Embench benchmarks
EMBENCH_DIR		:= sw/benchmarks/embench/src/	
EMBENCH_TESTS	:= $(shell find $(EMBENCH_DIR) -type d -exec basename {} \;)
EMBENCH_TESTS	:= $(filter-out src, $(EMBENCH_TESTS))
BENCHMARK_DIR_NAME=$(basename $BENCHMARK_DIR_PATH)
#run benchmarks parallel
PARALLEL_DIR    := sw/benchmarks/${SUITE}/src/
SKIP_TESTS 		:= src minver #sglib-combined # TODO: remove them from the list once they work
PARALLEL_TESTS	?= $(shell find $(PARALLEL_DIR) -type d -exec basename {} \;)
PARALLEL_TESTS	:= $(filter-out $(SKIP_TESTS), $(PARALLEL_TESTS))
PARALLEL_JOBS   := $(addprefix job_, ${PARALLEL_TESTS})
PARALLEL_DEBUG_JOBS := $(addsuffix -debug,$(PARALLEL_JOBS))
# ---------
# RTL simulation files
SIM_CORE_FILES 	:= $(shell find . -type f -name "*.core")
SIM_HDL_FILES 	:= $(shell find rtl -type f -name "*.v" -o -name "*.sv" -o -name "*.svh")
SIM_HDL_FILES 	+= $(shell find tb -type f -name "*.v" -o -name "*.sv" -o -name "*.svh")
SIM_CPP_FILES	:= $(shell find tb/verilator -type f -name "*.cpp" -o -name "*.hh")

#######################
# ----- TARGETS ----- #
#######################

# HDL source
# ----------
# Format code
.PHONY: format
format: | .check-fusesoc
	@echo "## Formatting RTL code..."
	fusesoc run --no-export --target format polito:len5:len5

# Static analysis
.PHONY: lint
lint: | .check-fusesoc
	@echo "## Running static analysis..."
	fusesoc run --no-export --target lint polito:len5:len5

# RTL simulation
# --------------
# Build Verilator models; the shell helper handles caching, locks and messages.
.PHONY: verilator-build verilator-build-debug
verilator-build: | .check-fusesoc
	@bash scripts/sim/build-verilator.sh sim "$(BUILD_DIR)/normal" $(FUSESOC_FLAGS)

verilator-build-debug: | .check-fusesoc
	@bash scripts/sim/build-verilator.sh sim-diff "$(DEBUG_BUILD_DIR)" $(FUSESOC_FLAGS)

# Run Verilator simulation
.PHONY: verilator-sim verilator-opt
verilator-sim: DUMP_WAVES ?= true
verilator-sim: DUMP_TRACE ?= true
verilator-opt: DUMP_WAVES ?= false
verilator-opt: DUMP_TRACE ?= false
verilator-sim verilator-opt: verilator-build $(FIRMWARE)
	@$(FUSESOC) run --no-export --target sim --tool verilator --run \
		--build-root "$(BUILD_DIR)/normal" $(FUSESOC_FLAGS) polito:len5:len5 \
		--log_level=$(LOG_LEVEL) \
		--firmware="$(abspath $(FIRMWARE))" \
		--max_cycles=$(MAX_CYCLES) \
		--dump_trace=$(DUMP_TRACE) \
		--dump_waves=$(DUMP_WAVES) \
		$(FUSESOC_ARGS)

# Run the same simulation with the Spike checker
.PHONY: verilator-sim-debug verilator-opt-debug
verilator-sim-debug: DUMP_WAVES ?= true
verilator-sim-debug: DUMP_TRACE ?= true
verilator-opt-debug: DUMP_WAVES ?= false
verilator-opt-debug: DUMP_TRACE ?= false
verilator-sim-debug verilator-opt-debug: verilator-build-debug $(FIRMWARE)
	@mkdir -p "$(SIM_RUN_DIR)"
	@$(FUSESOC) run --no-export --target sim-diff --tool verilator --run \
		--build-root "$(DEBUG_BUILD_DIR)" $(FUSESOC_FLAGS) polito:len5:len5 \
		--log_level=$(LOG_LEVEL) \
		--firmware="$(abspath $(FIRMWARE))" \
		--max_cycles=$(MAX_CYCLES) \
		--dump_trace=$(DUMP_TRACE) \
		--dump_waves=$(DUMP_WAVES) \
		--run_dir="$(abspath $(SIM_RUN_DIR))" \
		$(subst --diff-,--diff_,$(DEBUG_ARGS)) $(FUSESOC_ARGS)

$(BUILD_DIR)/sim-common/sim-trace.log: $(FIRMWARE) | verilator-build
	$(MAKE) --no-print-directory verilator-sim DUMP_TRACE=true

# Open dumped waveform with GTKWave
.PHONY: verilator-waves verilator-waves-debug
verilator-waves: $(BUILD_DIR)/sim-common/waves.fst | .check-gtkwave
	gtkwave -a tb/misc/verilator-waves.gtkw $< --rcvar 'fontname_signals Monospace $(FONT_SIZE)' --rcvar 'fontname_waves Monospace $(FONT_SIZE)'

verilator-waves-debug: $(SIM_RUN_DIR)/logs/diff/annotated.gtkw | .check-gtkwave
	gtkwave "$<" --rcvar 'fontname_signals Monospace $(FONT_SIZE)' --rcvar 'fontname_waves Monospace $(FONT_SIZE)'

$(BUILD_DIR)/sim-common/waves.fst:
	$(MAKE) --no-print-directory verilator-sim DUMP_WAVES=true

$(SIM_RUN_DIR)/logs/diff/annotated.gtkw:
	$(MAKE) --no-print-directory verilator-sim-debug DUMP_WAVES=true

# QuestaSim
.PHONY: questasim-sim
questasim-sim: | app .check-fusesoc $(BUILD_DIR)/
	@echo "## Running simulation with QuestaSim..."
	fusesoc run --no-export --target sim --tool modelsim $(FUSESOC_FLAGS) --build polito:len5:len5 2>&1 | tee build/build.log

# Benchmarking targets
# --------------------
.PHONY: run-benchmarks run-benchmarks-debug $(PARALLEL_JOBS) $(PARALLEL_DEBUG_JOBS)
run-benchmarks: verilator-build $(BUILD_DIR)/$(SUITE)/logs/sim/ $(PARALLEL_JOBS)
	@echo "## Getting the results from benchmarks"
	python3 scripts/parse_benchmarks.py -s $(SUITE) -p "$(BUILD_DIR)/$(SUITE)"
	@echo "$@ done."

run-benchmarks-debug: verilator-build-debug $(DEBUG_SUITE_DIR)/logs/sim/ $(PARALLEL_DEBUG_JOBS)
	@echo "## Getting the results from debug benchmarks"
	python3 scripts/parse_benchmarks.py -s $(SUITE) -p "$(DEBUG_SUITE_DIR)"
	@echo "$@ done."

$(PARALLEL_JOBS): job_%: verilator-build
	@$(MAKE) --no-print-directory run BENCHMARK=$* MAX_CYCLES=$(MAX_CYCLES)

$(PARALLEL_DEBUG_JOBS): job_%-debug: verilator-build-debug
	@$(MAKE) --no-print-directory run-debug BENCHMARK=$* MAX_CYCLES=$(MAX_CYCLES)

.PHONY: run run-debug
run-benchmarks run $(PARALLEL_JOBS): MAX_CYCLES = 10000000
run-benchmarks-debug run-debug $(PARALLEL_DEBUG_JOBS): MAX_CYCLES = 10000000
run: SOFTWARE_DIR = $(BUILD_DIR)/$(SUITE)/run/$(BENCHMARK)
run-debug: SOFTWARE_DIR = $(DEBUG_SUITE_DIR)/run/$(BENCHMARK)
run: $(BUILD_DIR)/$(SUITE)/run/$(BENCHMARK)/main.hex | verilator-build $(BUILD_DIR)/$(SUITE)/logs/sim/
	@echo "## Starting the simulation of $(SUITE) benchmark $(BENCHMARK)"
	@$(MAKE) --no-print-directory verilator-opt SOFTWARE_DIR="$(SOFTWARE_DIR)" FIRMWARE="$<" MAX_CYCLES=$(MAX_CYCLES) > "$(BUILD_DIR)/$(SUITE)/logs/sim/$(BENCHMARK).log" 2>&1
	@echo "## End of the simulation of $(SUITE) benchmark $(BENCHMARK)"

run-debug: $(DEBUG_SUITE_DIR)/run/$(BENCHMARK)/main.hex | verilator-build-debug $(DEBUG_SUITE_DIR)/logs/sim/
	@echo "## Starting the debug simulation of $(SUITE) benchmark $(BENCHMARK)"
	@$(MAKE) --no-print-directory verilator-opt-debug SOFTWARE_DIR="$(SOFTWARE_DIR)" FIRMWARE="$<" MAX_CYCLES=$(MAX_CYCLES) SIM_RUN_DIR="$(DEBUG_SUITE_DIR)/run/$(BENCHMARK)" > "$(DEBUG_SUITE_DIR)/logs/sim/$(BENCHMARK).log" 2>&1
	@echo "## End of the debug simulation of $(SUITE) benchmark $(BENCHMARK)"

$(BUILD_DIR)/$(SUITE)/run/$(BENCHMARK)/main.hex: | $(BUILD_DIR)/$(SUITE)/logs/compiler/
	@echo "## Building suite $(SUITE) benchmark $(BENCHMARK)"
	@$(MAKE) -BC sw benchmark SUITE=$(SUITE) BUILD_DIR="$(dir $@)" BENCHMARK=$(BENCHMARK) > "$(BUILD_DIR)/$(SUITE)/logs/compiler/$(BENCHMARK).log" 2>&1

$(DEBUG_SUITE_DIR)/run/$(BENCHMARK)/main.hex: | $(DEBUG_SUITE_DIR)/logs/compiler/
	@echo "## Building debug suite $(SUITE) benchmark $(BENCHMARK)"
	@$(MAKE) -BC sw benchmark SUITE=$(SUITE) BUILD_DIR="$(abspath $(dir $@))" BENCHMARK=$(BENCHMARK) CDEFS="$(CDEFS) -DSPIKE_CHECK" > "$(DEBUG_SUITE_DIR)/logs/compiler/$(BENCHMARK).log" 2>&1

# Software
# --------
# Application from 'sw/applications'
# NOTE: the -B option to make forces recompilation everytime, which is needed since PROJECT is user-defined
# The SPIKE_CHECK flag disables CSR instructions, since values differs between Spike and Verilator simulation 

.PHONY: app app-spike
app: | $(BUILD_DIR)/
	@echo "## Building application '$(PROJECT)'"
	$(MAKE) -BC sw app PROJECT=$(PROJECT) BUILD_DIR=$(BUILD_DIR) COPT=$(COPT)

$(BUILD_DIR)/spike/main.elf: app-spike
app-spike: | $(BUILD_DIR)/spike/
	@echo "## Building application '$(PROJECT)' with support for Spike"
	$(MAKE) -BC sw app PROJECT=$(PROJECT) BUILD_DIR=$(BUILD_DIR)/spike COPT=$(COPT) CDEFS=-DSPIKE_CHECK

.PHONY: benchmark benchmark-spike
benchmark:
	@echo "## Building suite $(SUITE) benchmark $(BENCHMARK)"
	$(MAKE) -BC sw benchmark SUITE=$(SUITE) BUILD_DIR=$(BUILD_DIR) BENCHMARK=$(BENCHMARK)

benchmark-spike: | $(BUILD_DIR)/spike/
	@echo "## Building suite $(SUITE) benchmark $(BENCHMARK)"
	$(MAKE) -BC sw benchmark SUITE=$(SUITE) BUILD_DIR=$(BUILD_DIR)/spike BENCHMARK=$(BENCHMARK) CDEFS=-DSPIKE_CHECK

# Simple test application
.PHONY: app-helloworld
app-helloworld:
	@echo "## Building helloworld application"
	$(MAKE) -BC sw PROJECT=hello_world BUILD_DIR=$(BUILD_DIR)

# Compile example applicationa and run RTL simulation
.PHONY: app-helloworld-questasim
run-helloworld-questasim: questasim-sim app-helloworld | .check-fusesoc
	@echo "## Running helloworld application"
	cd $(BUILD_DIR)/vlsi_polito_len5_0/sim-modelsim; \
	make run PLUSARGS="c firmware=../../../sw/applications/hello_world.hex"; \
	cd ../../..;

# Simulate the current application on Spike, in interactive mode (debug)
.PHONY: spike-sim
spike-sim: $(BUILD_DIR)/spike/main.elf
	@echo "## Running simulation with Spike..."
	spike -m0xf000:0x100000,0x20000000:0x1000 -d $<

# Simulate the current application on Spike in silent mode and generate the instruction execution trace
.PHONY: spike-trace
spike-trace: $(BUILD_DIR)/sim-common/spike-trace.log
$(BUILD_DIR)/sim-common/spike-trace.log: $(BUILD_DIR)/spike/main.elf | $(BUILD_DIR)/sim-common/
	@echo "## Running simulation with Spike..."
	spike --log-commits --log=$@ -l -m0xf000:0x100000,0x20000000:0x1000 $<

# Compare the execution traces from Spike and the Verilator simulation
.PHONY: spike-check
spike-check: verilator-build | $(BUILD_DIR)/sim-common/ .check-fusesoc
	@echo "## Launching Verilator simulation..."
	$(FUSESOC) run --no-export --target sim --tool verilator --run --build-root "$(BUILD_DIR)/normal" $(FUSESOC_FLAGS) polito:len5:len5 \
		--log_level=$(LOG_LEVEL) \
		--firmware=$(BUILD_DIR)/spike/main.hex \
		--max_cycles=$(MAX_CYCLES) \
		--dump_waves=true \
		--dump_trace=true \
		$(FUSESOC_ARGS)
	@echo "## Running Spike simulation..."
	spike --log-commits --log=$(BUILD_DIR)/sim-common/spike-trace.log -l -m0xf000:0x100000,0x20000000:0x1000 $(BUILD_DIR)/spike/main.elf
	@echo "## Comparing Spike and Verilator traces..."
	scripts/sim/cmp-trace.sh $(BUILD_DIR)/sim-common/sim-trace.log $(BUILD_DIR)/sim-common/spike-trace.log

# Check that nothing is broken
# ----------------------------
.PHONY: check
check: | check-alu .check-fusesoc
	@echo "### Executing regression tests..."
	@echo " ## Checking RTL..."
	fusesoc run --no-export --target format polito:len5:len5
	fusesoc run --no-export --target lint polito:len5:len5
	@echo " ## Simulating test applications..."
	$(foreach T, $(TESTS), eval $(MAKE) app-spike PROJECT=$(T) COPT=-O0 && $(MAKE) spike-check  || exit 1;)
	$(foreach T, $(TESTS), eval $(MAKE) app-spike PROJECT=$(T) COPT=-O1 && $(MAKE) spike-check  || exit 1;)
	$(foreach T, $(TESTS), eval $(MAKE) app-spike PROJECT=$(T) COPT=-O2 && $(MAKE) spike-check  || exit 1;)
	@echo "\e[1;32m### SUCCESS: all checks passed!\e[0m"
	@echo "### Running embench benchmark..."
	@echo "### NOTE: Rember to set appropriate MAX_CYCLES" 
	util/test-benchmark-suite.sh embench $(EMBENCH_DIR) $(MAX_CYCLES)

.PHONY: check-alu
check-alu: | .check-fusesoc
	@echo "## Checking ALU RTL..."
	fusesoc run --no-export --target sim --tool verilator polito:len5:alu-tb \
		--log_level=LOG_LOW \
		--dump_waves=false \
		--max_cycles=1000000

# Standalone frontend verification; no Spike, firmware or RTL formatting.
# Build once, then run independent native groups without concurrent FuseSoC setup.
.PHONY: check-frontend
# Serialize suites even with make -j; each suite retains its own JOBS/TEST_JOBS.
.NOTPARALLEL: check-frontend check-fetch-mem-if
check-frontend: check-pc-gen check-early-jump check-fetch-mem-if check-fetch-stage

.PHONY: check-pc-gen check-pc-gen-run pc-gen-build check-pc-gen-framework
check-pc-gen: REQUIRE_MATRIX ?= true
check-pc-gen: pc-gen-build
	@python3 tb/frontend/pc_gen/suite.py --binary "$$(python3 tb/frontend/pc_gen/configuration.py --binary --build-dir '$(BUILD_DIR)' --boot '$(or $(BOOT_PC),0)')" --output "$(BUILD_DIR)/pc-gen/suite" --test-jobs "$(or $(TEST_JOBS),$(JOBS))" --jobs "$(JOBS)" --seed "$(or $(SEED),1)" --seeds "$(or $(SEEDS),100)" --cycles "$(or $(CYCLES),10000)" --max-cycles "$(MAX_CYCLES)" --campaign "$(or $(CAMPAIGN),all)" --contract "$(or $(PC_GEN_CONTRACT),proposed)" --weights "$(WEIGHTS)" --guided "$(or $(GUIDED),true)" --journal "$(or $(JOURNAL),auto)" --log-level "$(LOG_LEVEL)" --waves "$(or $(DUMP_WAVES),false)" --require-matrix "$(REQUIRE_MATRIX)" $(if $(EARLY_ACCEPT),--early-accept=$(EARLY_ACCEPT)) $(if $(EARLY_TARGET),--early-target=$(EARLY_TARGET)) $(if $(INJECT_FAILURE),--inject-failure=$(INJECT_FAILURE))

# Former check-pc-gen behavior: directed T01-T22, or one SCENARIO for debugging.
check-pc-gen-run:
	@bash scripts/sim/check-pc-gen.sh

pc-gen-build:
	@PC_GEN_BUILD_ONLY=true bash scripts/sim/check-pc-gen.sh || { echo "Test failed: pc_gen build"; exit 1; }

check-pc-gen-framework: pc-gen-build
	python3 tb/frontend/pc_gen/validate.py --binary "$$(python3 tb/frontend/pc_gen/configuration.py --binary --build-dir '$(BUILD_DIR)' --boot '$(or $(BOOT_PC),0)')"

# Updated Vendored Files
# ----------------------
.PHONY: vendor-update
vendor-update:
	@echo "Updating vendored IPs..."
	find rtl/vendor -type f -name "*.vendor.hjson" -exec ./util/vendor.py -vU {} \;

# Explicit maintenance operation; ordinary builds never access the network.
.PHONY: vendor-update-spike
vendor-update-spike:
	python3 util/vendor.py -vU sw/vendor/riscv-isa-sim.vendor.hjson

# Utilities
# ---------
# Check if fusesoc is available
.PHONY: .check-fusesoc
.check-fusesoc:
	@if ! command -v "$(FUSESOC)" >/dev/null 2>&1; then \
	printf -- "### ERROR: 'fusesoc' is not in PATH. Is the correct conda environment active?\n" >&2; \
	exit 1; fi

# Check if GTKWave is available
.PHONY: .check-gtkwave
.check-gtkwave:
	@if [ ! `which gtkwave` ]; then \
	printf -- "### ERROR: 'gtkwave' is not in PATH. Is the correct conda environment active?\n" >&2; \
	exit 1; fi

# Run plotting scripts
.PHONY: charts
charts: w/benchmarks/embench/output/benchmarks.csv scripts/xheep_resultsO2.csv
	mkdir -p $(BUILD_DIR)/charts
	python3 scripts/ipc_charts.py --len5_report_file=sw/benchmarks/embench/output/backup_bench.csv --xheep_report_file=scripts/xheep_resultsO2.csv --chart_file=$(BUILD_DIR)/charts/ipc_chart.png

# Create new directories
%/:
	mkdir -p $@

# Clean-up
.PHONY: clean
clean: clean-app clean-sim clean-run

# Remove simulation, application and report outputs, retaining compiled Spike.
.PHONY: clean-keep-spike
clean-keep-spike:
	python3 util/clean-build.py --build-dir "$(BUILD_DIR)" --keep "$(SPIKE_BUILD)"

.PHONY: clean-run
clean-run:
	@rm -rf $(BUILD_DIR)/$(SUITE)

.PHONY: clean-sim
clean-sim:
	@rm -rf $(BUILD_DIR)

.PHONY: clean-app
clean-app:
	$(MAKE) -C sw clean

.PHONY: .print
.print:
	@echo "SIM_HDL_FILES: $(SIM_HDL_FILES)"
	@echo "SIM_CPP_FILES: $(SIM_CPP_FILES)"
	@echo "TESTS: $(TESTS)"

# Export variables for software linker script
# -------------------------------------------
export BUILD_DIR
export PROJECT
export LINKER
export COPT
export SPIKE_SRC SPIKE_BUILD VERILATOR JOBS FUSESOC VERBOSE

# Build once, then run isolated seed processes; jobs do not share artifacts.
.PHONY: check-pc-gen-random check-pc-gen-regression check-pc-gen-random-framework
check-pc-gen-random:
	@RANDOM_MODE=true bash scripts/sim/check-pc-gen.sh

check-pc-gen-regression: pc-gen-build
	python3 tb/frontend/pc_gen/regress.py --binary "$$(python3 tb/frontend/pc_gen/configuration.py --binary --build-dir '$(BUILD_DIR)' --boot '$(or $(BOOT_PC),0)')" --output "$(BUILD_DIR)/pc-gen/regression" --seed "$(or $(SEED),1)" --seeds "$(or $(SEEDS),100)" --cycles "$(or $(CYCLES),10000)" --campaign "$(or $(CAMPAIGN),all)" --contract "$(or $(PC_GEN_CONTRACT),proposed)" --weights "$(WEIGHTS)" --guided "$(or $(GUIDED),true)" --log-level "$(or $(LOG_LEVEL),LOG_LOW)" --waves "$(or $(DUMP_WAVES),false)" --journal "$(or $(JOURNAL),auto)" --jobs "$(or $(JOBS),1)" $(if $(EARLY_ACCEPT),--early-accept=$(EARLY_ACCEPT)) $(if $(EARLY_TARGET),--early-target=$(EARLY_TARGET)) $(if $(filter true,$(REQUIRE_MATRIX)),--require-matrix)

check-pc-gen-random-framework: pc-gen-build
	python3 tb/frontend/pc_gen/validate_random.py --binary "$$(python3 tb/frontend/pc_gen/configuration.py --binary --build-dir '$(BUILD_DIR)' --boot '$(or $(BOOT_PC),0)')"

# Disposable copies of pc_gen only; selected production packages stay untouched.
.PHONY: check-pc-gen-mutations
check-pc-gen-mutations: pc-gen-build
	python3 tb/frontend/pc_gen/mutate.py --binary "$$(python3 tb/frontend/pc_gen/configuration.py --binary --build-dir '$(BUILD_DIR)' --boot '$(or $(BOOT_PC),0)')" --output "$(BUILD_DIR)/pc-gen/mutation" --jobs "$(or $(JOBS),2)"

# Standalone early_jump_unit with its real RAS. Configuration comes only from RTL packages.
.PHONY: early-jump-build check-early-jump check-early-jump-run check-early-jump-framework check-early-jump-random check-early-jump-random-framework check-early-jump-regression check-early-jump-mutations
EARLY_JUMP_BINARY = $$(python3 tb/frontend/early_jump_unit/configuration.py --binary --build-dir '$(BUILD_DIR)')
EARLY_JUMP_POLICIES = $(if $(RAS_ORDER),--order=$(RAS_ORDER)) $(if $(RAS_EXCEPTION),--exception=$(RAS_EXCEPTION)) $(if $(RAS_BOUNDARIES),--boundaries=$(RAS_BOUNDARIES)) $(if $(EARLY_LIFECYCLE),--lifecycle=$(EARLY_LIFECYCLE))
early-jump-build:
	@EARLY_JUMP_BUILD_ONLY=true bash scripts/sim/check-early-jump.sh

check-early-jump: REQUIRE_MATRIX ?= true
check-early-jump: early-jump-build
	@python3 tb/frontend/early_jump_unit/suite.py --binary "$(EARLY_JUMP_BINARY)" --output "$(BUILD_DIR)/early-jump/suite" --test-jobs "$(or $(TEST_JOBS),$(JOBS))" --jobs "$(JOBS)" --seed "$(or $(SEED),1)" --seeds "$(or $(SEEDS),100)" --cycles "$(or $(CYCLES),10000)" --max-cycles "$(MAX_CYCLES)" --campaign "$(or $(CAMPAIGN),all)" --contract "$(or $(EARLY_JUMP_CONTRACT),len5_minimal)" --weights "$(WEIGHTS)" --guided "$(or $(GUIDED),true)" --journal "$(or $(JOURNAL),auto)" --log-level "$(LOG_LEVEL)" --waves "$(or $(DUMP_WAVES),false)" --require-matrix "$(REQUIRE_MATRIX)" $(EARLY_JUMP_POLICIES) $(if $(INJECT_FAILURE),--inject-failure=$(INJECT_FAILURE))

check-early-jump-run:
	@LOG_LEVEL="$(LOG_LEVEL)" MAX_CYCLES="$(MAX_CYCLES)" bash scripts/sim/check-early-jump.sh

check-early-jump-framework: early-jump-build
	@python3 tb/frontend/early_jump_unit/validate.py --binary "$(EARLY_JUMP_BINARY)" --output "$(BUILD_DIR)/early-jump/validation"

check-early-jump-random:
	@RANDOM_MODE=true LOG_LEVEL="$(LOG_LEVEL)" MAX_CYCLES="$(MAX_CYCLES)" bash scripts/sim/check-early-jump.sh

check-early-jump-random-framework: early-jump-build
	@python3 tb/frontend/early_jump_unit/validate_random.py --binary "$(EARLY_JUMP_BINARY)" --output "$(BUILD_DIR)/early-jump/validation"

check-early-jump-regression: early-jump-build
	@python3 tb/frontend/early_jump_unit/regress.py --binary "$(EARLY_JUMP_BINARY)" --output "$(BUILD_DIR)/early-jump/regression" --seed "$(or $(SEED),1)" --seeds "$(or $(SEEDS),100)" --cycles "$(or $(CYCLES),10000)" --campaign "$(or $(CAMPAIGN),all)" --contract "$(or $(EARLY_JUMP_CONTRACT),len5_minimal)" --weights "$(WEIGHTS)" --guided "$(or $(GUIDED),true)" --journal "$(or $(JOURNAL),auto)" --log-level "$(LOG_LEVEL)" --waves "$(or $(DUMP_WAVES),false)" --jobs "$(JOBS)" $(EARLY_JUMP_POLICIES) $(if $(filter true,$(REQUIRE_MATRIX)),--require-matrix)

check-early-jump-mutations: early-jump-build
	@python3 tb/frontend/early_jump_unit/mutate.py --binary "$(EARLY_JUMP_BINARY)" --output "$(BUILD_DIR)/early-jump/mutation" --jobs "$(JOBS)"

# Standalone fetch_mem_if: actual FIFO/spill dependencies; RTL source selects N.
.PHONY: fetch-mem-if-build check-fetch-mem-if check-fetch-mem-if-cancel check-fetch-mem-if-run check-fetch-mem-if-framework check-fetch-mem-if-random check-fetch-mem-if-random-framework check-fetch-mem-if-regression check-fetch-mem-if-mutations
FETCH_MEM_BINARY = $$(python3 tb/frontend/fetch_mem_if/configuration.py --binary --build-dir '$(BUILD_DIR)')
fetch-mem-if-build:
	@FETCH_MEM_BUILD_ONLY=true bash scripts/sim/check-fetch-mem-if.sh

check-fetch-mem-if: check-fetch-mem-if-cancel check-fetch-mem-if-drain

check-fetch-mem-if-cancel: REQUIRE_MATRIX ?= true
check-fetch-mem-if-cancel: fetch-mem-if-build
	@python3 tb/frontend/fetch_mem_if/suite.py --binary "$(FETCH_MEM_BINARY)" --output "$(BUILD_DIR)/fetch-mem-if/suite" --test-jobs "$(or $(TEST_JOBS),$(JOBS))" --jobs "$(JOBS)" --seed "$(or $(SEED),1)" --seeds "$(or $(SEEDS),100)" --cycles "$(or $(CYCLES),10000)" --max-cycles "$(MAX_CYCLES)" --campaign "$(or $(CAMPAIGN),all)" --contract "$(or $(FETCH_MEM_CONTRACT),integrated)" --weights "$(WEIGHTS)" --guided "$(or $(GUIDED),true)" --journal "$(or $(JOURNAL),auto)" --log-level "$(LOG_LEVEL)" --waves "$(or $(DUMP_WAVES),false)" --require-matrix "$(REQUIRE_MATRIX)" $(if $(INJECT_FAILURE),--inject-failure=$(INJECT_FAILURE))

check-fetch-mem-if-run:
	@LOG_LEVEL="$(LOG_LEVEL)" MAX_CYCLES="$(MAX_CYCLES)" bash scripts/sim/check-fetch-mem-if.sh

check-fetch-mem-if-framework: fetch-mem-if-build
	@python3 tb/frontend/fetch_mem_if/validate.py --binary "$(FETCH_MEM_BINARY)" --output "$(BUILD_DIR)/fetch-mem-if/validation"

check-fetch-mem-if-random:
	@RANDOM_MODE=true LOG_LEVEL="$(LOG_LEVEL)" MAX_CYCLES="$(MAX_CYCLES)" bash scripts/sim/check-fetch-mem-if.sh

check-fetch-mem-if-random-framework: fetch-mem-if-build
	@python3 tb/frontend/fetch_mem_if/validate_random.py --binary "$(FETCH_MEM_BINARY)" --output "$(BUILD_DIR)/fetch-mem-if/validation"

check-fetch-mem-if-regression: fetch-mem-if-build
	@python3 tb/frontend/fetch_mem_if/regress.py --binary "$(FETCH_MEM_BINARY)" --output "$(BUILD_DIR)/fetch-mem-if/regression" --seed "$(or $(SEED),1)" --seeds "$(or $(SEEDS),100)" --cycles "$(or $(CYCLES),10000)" --campaign "$(or $(CAMPAIGN),all)" --contract "$(or $(FETCH_MEM_CONTRACT),integrated)" --weights "$(WEIGHTS)" --guided "$(or $(GUIDED),true)" --journal "$(or $(JOURNAL),auto)" --log-level "$(LOG_LEVEL)" --waves "$(or $(DUMP_WAVES),false)" --jobs "$(JOBS)" $(if $(filter true,$(REQUIRE_MATRIX)),--require-matrix)

check-fetch-mem-if-mutations: fetch-mem-if-build
	@python3 tb/frontend/fetch_mem_if/mutate.py --binary "$(FETCH_MEM_BINARY)" --output "$(BUILD_DIR)/fetch-mem-if/mutation" --jobs "$(JOBS)"

# Directed native-memory drain protocol at the source-selected depth and width.
.PHONY: check-fetch-mem-if-drain
check-fetch-mem-if-drain:
	@$(FUSESOC) run --target drain --tool verilator --build-root "$(BUILD_DIR)/fetch-mem-if/drain" polito:len5:fetch-mem-if-tb

# Closed-loop complete production frontend. Only source-selected configuration.
STRICT_COMPLETION ?= false
export STRICT_COMPLETION
.PHONY: fetch-stage-build check-fetch-stage check-fetch-stage-run check-fetch-stage-framework check-fetch-stage-random check-fetch-stage-random-framework check-fetch-stage-regression check-fetch-stage-mutations
FETCH_STAGE_BINARY = $$(python3 tb/frontend/fetch_stage/configuration.py --binary --build-dir '$(BUILD_DIR)')
fetch-stage-build:
	@BUILD_DIR="$(BUILD_DIR)" FUSESOC="$(FUSESOC)" python3 tb/frontend/fetch_stage/run.py --build-only

check-fetch-stage: fetch-stage-build
	@python3 tb/frontend/fetch_stage/suite.py --binary "$(FETCH_STAGE_BINARY)" --output "$(BUILD_DIR)/fetch-stage/suite" --jobs "$(JOBS)" --test-jobs "$(or $(TEST_JOBS),3)"

check-fetch-stage-run:
	@BUILD_DIR="$(BUILD_DIR)" FUSESOC="$(FUSESOC)" LOG_LEVEL="$(LOG_LEVEL)" python3 tb/frontend/fetch_stage/run.py

check-fetch-stage-framework: fetch-stage-build
	@python3 tb/frontend/fetch_stage/validate.py --binary "$(FETCH_STAGE_BINARY)" --output "$(BUILD_DIR)/fetch-stage/validation"

check-fetch-stage-random:
	@BUILD_DIR="$(BUILD_DIR)" FUSESOC="$(FUSESOC)" LOG_LEVEL="$(LOG_LEVEL)" python3 tb/frontend/fetch_stage/run.py --random

check-fetch-stage-random-framework: fetch-stage-build
	@python3 tb/frontend/fetch_stage/validate.py --random --binary "$(FETCH_STAGE_BINARY)" --output "$(BUILD_DIR)/fetch-stage/validation"

check-fetch-stage-regression: fetch-stage-build
	@python3 tb/frontend/fetch_stage/regress.py --binary "$(FETCH_STAGE_BINARY)" --output "$(BUILD_DIR)/fetch-stage/regression" --seed "$(or $(SEED),1)" --seeds "$(or $(SEEDS),100)" --cycles "$(or $(CYCLES),10000)" --jobs "$(JOBS)" $(if $(filter true,$(REQUIRE_MATRIX)),--require-matrix)

check-fetch-stage-mutations: fetch-stage-build
	@python3 tb/frontend/fetch_stage/mutate.py --binary "$(FETCH_STAGE_BINARY)" --output "$(BUILD_DIR)/fetch-stage/mutation" --jobs "$(or $(JOBS),2)" $(if $(MUTATIONS),--only=$(MUTATIONS))

# Focused audit workflows: private production configurations and explicit scope.
.PHONY: check-fetch-stage-widths-smoke check-fetch-stage-core
check-fetch-stage-widths-smoke:
	@FUSESOC="$(FUSESOC)" python3 tb/frontend/fetch_stage/widths_smoke.py --output "$(BUILD_DIR)/fetch-stage/widths-smoke"

check-fetch-stage-core: fetch-stage-build
	@python3 tb/frontend/fetch_stage/core.py --binary "$(FETCH_STAGE_BINARY)" --output "$(BUILD_DIR)/fetch-stage/core" --jobs "$(or $(JOBS),2)"

# Independent SRAM protocol, lane conversion, exception and randomized tests.
.PHONY: check-tc-sram
check-tc-sram:
	@SEEDS="$(or $(SEEDS),10)" CYCLES="$(or $(CYCLES),10000)" JOBS="$(JOBS)" bash scripts/sim/check-tc-sram.sh
