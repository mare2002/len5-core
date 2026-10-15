// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Adapted from pc_gen_configuration.cpp; startup audit never selects dynamic state.
#include "early_jump_model.hh"
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>
namespace len5::early {
static std::string contents(const std::filesystem::path& p) {
    std::ifstream f(p,std::ios::binary);
    if(!f) throw std::invalid_argument("build/configuration failure: cannot read "+p.string());
    std::ostringstream s; s<<f.rdbuf(); return s.str();
}
Config read_build_configuration(const std::string& executable) {
    const auto directory=std::filesystem::canonical(executable).parent_path();
    std::istringstream stream(contents(directory/"early_jump_build.cfg"));
    std::map<std::string,std::string> fields;
    std::string line,source; unsigned snapshots=0;
    while(std::getline(stream,line)) {
        const auto equal=line.find('=');
        if(equal==std::string::npos) throw std::invalid_argument("malformed early_jump build metadata");
        const auto key=line.substr(0,equal),value=line.substr(equal+1);
        if(key=="source_file") source=value;
        else if(key=="snapshot") {
            if(source.empty() || contents(source)!=contents(directory/value))
                throw std::invalid_argument("stale early_jump binary: source changed: "+source+"; rebuild");
            ++snapshots; source.clear();
        } else if(!fields.emplace(key,value).second) throw std::invalid_argument("duplicate configuration field");
    }
    if(!snapshots || !source.empty()) throw std::invalid_argument("build metadata lacks verified source snapshots");
    const auto number=[&](const char* key) {
        const auto& value=fields.at(key); size_t end=0; const auto n=std::stoull(value,&end,10);
        if(value.empty() || value[0]=='-' || end!=value.size() || n>UINT32_MAX) throw std::invalid_argument("invalid configuration number");
        return unsigned(n);
    };
    Config c; c.lanes=number("bundle_instructions"); c.depth=number("ras_depth"); c.xlen=number("xlen");
    c.alen=number("alen"); c.instruction_bytes=number("instruction_bytes");
    c.source=fields.at("source"); c.fingerprint=fields.at("fingerprint"); c.validate();
    if(number("bundle_bytes")!=c.bundle_bytes() || number("issue_bits")!=(c.lanes==1?0:c.lanes==2?1:c.lanes==4?2:3))
        throw std::invalid_argument("inconsistent derived configuration metadata");
    return c;
}
} // namespace len5::early
