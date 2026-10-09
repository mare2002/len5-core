#pragma once
#include "checker.hh"
namespace len5::diff {
// ABI is deliberately confined to this translation unit and pinned Spike source/build trees.
class SpikeReference final : public Reference {
  public:
    SpikeReference(const std::string &hex_file, uint64_t boot_pc,
                   const std::string &isa = "RV64IMFD",
                   const std::map<uint32_t, uint64_t> &initial_csrs = {});
    ~SpikeReference();
    ReferenceRecord step() override;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace len5::diff
