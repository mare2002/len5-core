ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
OUT ?= $(ROOT)/build/diff-unit
CXX ?= g++
VERILATOR_ROOT ?= /usr/share/verilator
CPPFLAGS += -I$(ROOT)/tb/verilator/diff -I$(VERILATOR_ROOT)/include
CXXFLAGS += -std=c++17 -O1 -g -Wall -Wextra
.PHONY: test
test: $(OUT)/checker-test
	$(OUT)/checker-test $(OUT)/cases
$(OUT)/fst_support.o: $(ROOT)/tests/diff/fst_support.cpp
	mkdir -p $(OUT)
	$(CXX) $(CPPFLAGS) -std=c++17 -O1 -c $< -o $@
$(OUT)/checker-test: $(ROOT)/tests/diff/checker_test.cpp $(ROOT)/tb/verilator/diff/checker.cpp $(ROOT)/tb/verilator/diff/annotate.cpp $(ROOT)/tb/verilator/diff/checker.hh $(ROOT)/tb/verilator/diff/monitor.hh $(OUT)/fst_support.o
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(filter %.cpp %.o,$^) -lz -o $@
