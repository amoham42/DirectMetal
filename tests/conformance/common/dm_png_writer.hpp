#pragma once

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

namespace dm {

namespace detail {

inline uint32_t crc32_update(uint32_t crc, const uint8_t* data, size_t len) {
    uint32_t c = crc ^ 0xFFFFFFFFu;
    for (size_t i = 0; i < len; ++i) {
        c ^= data[i];
        for (int b = 0; b < 8; ++b) {
            c = (c >> 1) ^ ((c & 1u) ? 0xEDB88320u : 0u);
        }
    }
    return c ^ 0xFFFFFFFFu;
}

inline uint32_t adler32(const uint8_t* data, size_t len) {
    uint32_t s1 = 1;
    uint32_t s2 = 0;
    constexpr uint32_t kMod = 65521u;
    for (size_t i = 0; i < len; ++i) {
        s1 = (s1 + data[i]) % kMod;
        s2 = (s2 + s1) % kMod;
    }
    return (s2 << 16) | s1;
}

inline void append_be32(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xFFu));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xFFu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xFFu));
    out.push_back(static_cast<uint8_t>(v & 0xFFu));
}

inline void append_le16(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xFFu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xFFu));
}

inline void append_chunk(std::vector<uint8_t>& out, const char type[4],
                         const uint8_t* data, uint32_t len) {
    append_be32(out, len);
    const size_t type_pos = out.size();
    out.insert(out.end(), type, type + 4);
    if (len > 0 && data != nullptr) {
        out.insert(out.end(), data, data + len);
    }
    const uint32_t crc = crc32_update(0u, out.data() + type_pos, 4u + len);
    append_be32(out, crc);
}

}  // namespace detail

// Zero-dependency standards-compliant 8-bit RGBA lossless PNG writer.
inline bool write_png_rgba8(const std::string& path, uint32_t width, uint32_t height,
                            const uint8_t* rgba, uint32_t row_pitch_bytes) {
    if (width == 0 || height == 0 || rgba == nullptr || row_pitch_bytes < width * 4u) {
        return false;
    }

    const size_t row_bytes = static_cast<size_t>(width) * 4u;
    const size_t raw_size = static_cast<size_t>(height) * (1u + row_bytes);
    std::vector<uint8_t> raw;
    raw.reserve(raw_size);

    for (uint32_t y = 0; y < height; ++y) {
        raw.push_back(0x00u);  // Filter type 0 (None)
        const uint8_t* row = rgba + static_cast<size_t>(y) * row_pitch_bytes;
        raw.insert(raw.end(), row, row + row_bytes);
    }

    // Build zlib stream using uncompressed DEFLATE stored blocks (max 65535 bytes per block).
    std::vector<uint8_t> zlib_stream;
    zlib_stream.reserve(raw.size() + 64u + (raw.size() / 65535u) * 5u);
    zlib_stream.push_back(0x78u);  // CMF: deflate, 32K window
    zlib_stream.push_back(0x01u);  // FLG: FCHECK valid, no dict, fastest

    size_t offset = 0;
    while (offset < raw.size()) {
        const size_t remaining = raw.size() - offset;
        const uint16_t block_len = static_cast<uint16_t>(remaining > 65535u ? 65535u : remaining);
        const uint8_t bfinal = (offset + block_len == raw.size()) ? 0x01u : 0x00u;
        zlib_stream.push_back(bfinal);  // BFINAL | BTYPE=00
        detail::append_le16(zlib_stream, block_len);
        detail::append_le16(zlib_stream, static_cast<uint16_t>(~block_len));
        zlib_stream.insert(zlib_stream.end(), raw.begin() + static_cast<ptrdiff_t>(offset),
                           raw.begin() + static_cast<ptrdiff_t>(offset + block_len));
        offset += block_len;
    }

    detail::append_be32(zlib_stream, detail::adler32(raw.data(), raw.size()));

    std::vector<uint8_t> png;
    png.reserve(8u + 25u + 12u + zlib_stream.size() + 12u);
    static constexpr uint8_t kSig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
    png.insert(png.end(), kSig, kSig + 8);

    std::vector<uint8_t> ihdr;
    ihdr.reserve(13);
    detail::append_be32(ihdr, width);
    detail::append_be32(ihdr, height);
    ihdr.push_back(8);  // bit depth
    ihdr.push_back(6);  // color type: RGBA
    ihdr.push_back(0);  // compression
    ihdr.push_back(0);  // filter
    ihdr.push_back(0);  // interlace
    detail::append_chunk(png, "IHDR", ihdr.data(), static_cast<uint32_t>(ihdr.size()));

    detail::append_chunk(png, "IDAT", zlib_stream.data(),
                         static_cast<uint32_t>(zlib_stream.size()));
    detail::append_chunk(png, "IEND", nullptr, 0);

    std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
    if (!ofs.is_open()) {
        return false;
    }
    ofs.write(reinterpret_cast<const char*>(png.data()),
              static_cast<std::streamsize>(png.size()));
    return ofs.good();
}

}  // namespace dm
