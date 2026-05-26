#include "bundle/Crc32.h"

#include <array>

namespace crater::bundle {

namespace {

// Reflected CRC-32 table for polynomial 0xEDB88320 (the reflected form of the
// 0x04C11DB7 generator). Built at compile time so we don't pay a per-process
// init cost and the table sits in .rodata.
constexpr std::array<uint32_t, 256> buildTable() noexcept
{
    std::array<uint32_t, 256> t{};
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int k = 0; k < 8; ++k) {
            c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        }
        t[i] = c;
    }
    return t;
}

constexpr auto kTable = buildTable();

}  // namespace

void Crc32::update(QByteArrayView bytes) noexcept
{
    uint32_t s = m_state;
    const auto* p = reinterpret_cast<const uint8_t*>(bytes.data());
    const auto  n = bytes.size();
    for (qsizetype i = 0; i < n; ++i) {
        s = kTable[(s ^ p[i]) & 0xFFu] ^ (s >> 8);
    }
    m_state = s;
}

uint32_t Crc32::of(QByteArrayView bytes) noexcept
{
    Crc32 c;
    c.update(bytes);
    return c.value();
}

}  // namespace crater::bundle
