#pragma once

#include "dm_metrics.hpp"

#include <dxgi.h>
#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <string>

namespace dm {

namespace detail {

inline std::string wide_to_utf8(const wchar_t* wstr) {
    if (!wstr || !wstr[0]) return {};
    const int needed = WideCharToMultiByte(CP_UTF8, 0, wstr, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return {};
    std::string out(static_cast<size_t>(needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wstr, -1, out.data(), needed, nullptr, nullptr);
    return out;
}

inline std::string to_lower_ascii(std::string s) {
    for (char& c : s) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

}  // namespace detail

struct SelectedAdapter {
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    AdapterMetadata meta;
};

inline bool select_hardware_adapter(const std::string& filter_substr, SelectedAdapter& out) {
    Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
        return false;
    }

    const std::string needle = detail::to_lower_ascii(filter_substr);
    bool found_any = false;
    uint64_t best_score = 0;

    Microsoft::WRL::ComPtr<IDXGIAdapter1> fallback;
    AdapterMetadata fallback_meta;

    for (UINT idx = 0;; ++idx) {
        Microsoft::WRL::ComPtr<IDXGIAdapter1> candidate;
        if (factory->EnumAdapters1(idx, &candidate) == DXGI_ERROR_NOT_FOUND) {
            break;
        }
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(candidate->GetDesc1(&desc))) {
            continue;
        }

        AdapterMetadata meta;
        meta.description = detail::wide_to_utf8(desc.Description);
        meta.vendor_id = desc.VendorId;
        meta.device_id = desc.DeviceId;
        meta.dedicated_vram_mb = static_cast<uint64_t>(desc.DedicatedVideoMemory) / (1024ULL * 1024ULL);
        meta.shared_mem_mb = static_cast<uint64_t>(desc.SharedSystemMemory) / (1024ULL * 1024ULL);

        if (!fallback) {
            fallback = candidate;
            fallback_meta = meta;
        }

        const bool is_software = (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0 ||
                                 (desc.VendorId == 0x1414 && desc.DeviceId == 0x008c);
        if (is_software) {
            continue;
        }

        if (!needle.empty()) {
            const std::string hay = detail::to_lower_ascii(meta.description);
            if (hay.find(needle) != std::string::npos) {
                out.adapter = candidate;
                out.meta = meta;
                return true;
            }
            continue;
        }

        // Prefer dedicated VRAM; break ties toward non-Microsoft discrete GPUs.
        const uint64_t score = (meta.dedicated_vram_mb * 1024ULL) +
                               (desc.VendorId == 0x10DE ? 100ULL : 10ULL);
        if (!found_any || score > best_score) {
            best_score = score;
            out.adapter = candidate;
            out.meta = meta;
            found_any = true;
        }
    }

    if (found_any) {
        return true;
    }
    if (needle.empty() && fallback) {
        out.adapter = fallback;
        out.meta = fallback_meta;
        return true;
    }
    return false;
}

}  // namespace dm
