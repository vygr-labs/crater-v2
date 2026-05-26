#pragma once

#include <QByteArrayView>
#include <cstdint>

namespace crater::bundle {

// CRC-32 (IEEE 802.3 / zip / gzip / PNG polynomial 0xEDB88320).
//
// Qt's public API exposes only CRC-16 (qChecksum). ZIP entries require CRC-32
// over the uncompressed bytes — see APPNOTE.TXT §4.4.7 — so we ship a small
// table-based implementation here. ~30 lines including the lookup table.
class Crc32
{
public:
    Crc32() = default;

    void update(QByteArrayView bytes) noexcept;
    uint32_t value() const noexcept { return ~m_state; }

    // One-shot convenience.
    static uint32_t of(QByteArrayView bytes) noexcept;

private:
    uint32_t m_state = 0xFFFFFFFFu;
};

}  // namespace crater::bundle
