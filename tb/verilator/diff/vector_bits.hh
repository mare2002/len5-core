#pragma once
#include <algorithm>
#include <cstdint>

namespace len5::diff {
// Extract a validated field of at most 64 bits from a VPI vector. Check bval
// only within the field, including fields spanning three 32-bit words.
template <typename Word>
bool vector_bits(const Word *words, unsigned offset, unsigned width, uint64_t &value) {
    value = 0;
    for (unsigned copied = 0; copied < width;) {
        const unsigned position = offset + copied, shift = position % 32;
        const unsigned count = std::min(width - copied, 32 - shift);
        const uint32_t mask = static_cast<uint32_t>((uint64_t{1} << count) - 1);
        const auto &word = words[position / 32];
        if ((static_cast<uint32_t>(word.bval) >> shift) & mask)
            return false;
        value |= uint64_t((static_cast<uint32_t>(word.aval) >> shift) & mask) << copied;
        copied += count;
    }
    return true;
}
} // namespace len5::diff
