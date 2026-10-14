// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "pc_gen_model.hh"

namespace len5::pcgen {
struct BuildConfiguration {
    Config expected;
    unsigned alen=0, issue_bits=0, instruction_bits=0, lwidth=0;
    std::string fingerprint, source;
};
// Reads build metadata and verifies immutable package snapshots against source.
// Has no access to DUT outputs or model state.
BuildConfiguration read_build_configuration(const std::string& executable);
} // namespace len5::pcgen
