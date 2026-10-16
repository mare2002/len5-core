// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Adapted from pc_gen_configuration.cpp; startup audit never selects dynamic state.
#include "fetch_stage_components.hh"
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>
namespace len5::frontend {
static std::string contents(const std::filesystem::path &p) {
    std::ifstream f(p, std::ios::binary);
    if (!f)
        throw std::invalid_argument("build/configuration failure: cannot read " + p.string());
    std::ostringstream s;
    s << f.rdbuf();
    return s.str();
}
Config read_configuration(const std::string &executable) {
    const auto directory = std::filesystem::canonical(executable).parent_path();
    std::istringstream stream(contents(directory / "fetch_stage_build.cfg"));
    std::map<std::string, std::string> fields;
    std::string line, source;
    unsigned snapshots = 0;
    while (std::getline(stream, line)) {
        const auto equal = line.find('=');
        if (equal == std::string::npos)
            throw std::invalid_argument("malformed fetch_stage build metadata");
        const auto key = line.substr(0, equal), value = line.substr(equal + 1);
        if (key == "source_file")
            source = value;
        else if (key == "snapshot") {
            if (source.empty() || contents(source) != contents(directory / value))
                throw std::invalid_argument("stale fetch_stage binary: source changed: " + source +
                                            "; rebuild");
            ++snapshots;
            source.clear();
        } else if (!fields.emplace(key, value).second)
            throw std::invalid_argument("duplicate configuration field");
    }
    if (!snapshots || !source.empty())
        throw std::invalid_argument("build metadata lacks verified source snapshots");
    const auto number = [&](const char *key) {
        const auto &value = fields.at(key);
        size_t end = 0;
        const auto n = std::stoull(value, &end, 10);
        if (value.empty() || value[0] == '-' || end != value.size() || n > UINT32_MAX)
            throw std::invalid_argument("invalid configuration number");
        return unsigned(n);
    };
    Config c;
    c.lanes = number("bundle_instructions");
    c.depth = number("metadata_depth");
    c.hlen = number("hlen");
    c.btb_bits = number("btb_bits");
    c.initial = number("initial");
    c.ras_depth = number("ras_depth");
    c.iq = number("iq");
    c.rob = number("rob");
    c.branch_capacity = number("branch_capacity");
    c.boot = std::stoull(fields.at("boot_pc"));
    c.source = fields.at("source");
    c.fingerprint = fields.at("fingerprint");
    c.validate();
    if (number("xlen") != 64 || number("alen") != 64 || number("instruction_bytes") != 4 ||
        number("cause_bits") != 5 || number("request_skip") != 1 || number("answer_skip") != 0 ||
        number("bundle_bytes") != c.bytes())
        throw std::invalid_argument("FE01: inconsistent build configuration");
    return c;
}
} // namespace len5::frontend
