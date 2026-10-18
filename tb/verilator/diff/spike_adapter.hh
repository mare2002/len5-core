#pragma once
#include "checker.hh"
namespace len5::diff {
struct MemoryMap {
    uint64_t serial = 0x20000000, exit = 0x20000100;
    uint64_t base = 0, size = 0; // size zero preserves the legacy sparse map
    uint64_t mmio_mask = 0xffffffffe0000000;
};
// ABI is deliberately confined to this translation unit and pinned Spike source/build trees.
class SpikeReference final : public Reference {
  public:
    SpikeReference(const std::string &hex_file, uint64_t boot_pc,
                   const std::string &isa = "RV64IMFD",
                   const std::map<uint32_t, uint64_t> &initial_csrs = {}, MemoryMap memory_map = {});
    ~SpikeReference();
    ReferenceRecord step() override;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace len5::diff
