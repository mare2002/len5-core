// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "pc_gen_configuration.hh"
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <stdexcept>

namespace len5::pcgen {
static std::string contents(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    if(!file) throw std::invalid_argument("build/configuration failure: cannot read "+path.string()+"; run make pc-gen-build");
    std::ostringstream text; text<<file.rdbuf(); return text.str();
}
BuildConfiguration read_build_configuration(const std::string& executable) {
    const auto directory=std::filesystem::canonical(executable).parent_path();
    std::istringstream stream(contents(directory/"pc_gen_build.cfg"));
    std::map<std::string,std::string> fields;
    std::string line, package;
    unsigned snapshots=0;
    while(std::getline(stream,line)) {
        const auto equal=line.find('=');
        if(equal==std::string::npos) throw std::invalid_argument("malformed pc_gen build metadata");
        const auto key=line.substr(0,equal), value=line.substr(equal+1);
        if(key=="package") package=value;
        else if(key=="snapshot") {
            if(package.empty() || contents(package)!=contents(directory/value))
                throw std::invalid_argument("stale pc_gen binary: RTL package changed: "+package+"; run make pc-gen-build");
            ++snapshots; package.clear();
        } else if(!fields.emplace(key,value).second) throw std::invalid_argument("duplicate pc_gen build metadata field");
    }
    if(!snapshots || !package.empty()) throw std::invalid_argument("pc_gen build metadata lacks verified package snapshots");
    const auto number=[&](const char* key) {
        const auto& value=fields.at(key); size_t end=0;
        const auto n=std::stoull(value,&end,10);
        if(end!=value.size() || value.empty() || value[0]=='-') throw std::invalid_argument("invalid pc_gen configuration number");
        return n;
    };
    BuildConfiguration config;
    config.expected={number("boot_pc"),unsigned(number("xlen")),unsigned(number("instruction_bytes")),unsigned(number("bundle_instructions"))};
    config.expected.validate();
    config.alen=unsigned(number("alen")); config.issue_bits=unsigned(number("issue_bits"));
    config.instruction_bits=unsigned(number("instruction_bits")); config.lwidth=unsigned(number("lwidth"));
    config.fingerprint=fields.at("fingerprint"); config.source=fields.at("source");
    if(number("bundle_bytes")!=config.expected.bundle_bytes()) throw std::invalid_argument("inconsistent bundle configuration metadata");
    return config;
}
} // namespace len5::pcgen
