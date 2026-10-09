#pragma once
#include "checker.hh"
#include "spike_adapter.hh"
#include <memory>
namespace len5::diff {
class Monitor {
  public:
    Monitor(const std::string &firmware, const std::string &output, Config,
            const std::string &fault);
    ~Monitor();
    void before_rising(Stamp);
    void after_rising(Stamp);
    void before_falling(Stamp);
    bool stopped() const;
    int finish(bool normal_exit, Stamp, const std::string &original_fst);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
void annotate(const std::string &original, const Checker &checker);
} // namespace len5::diff
