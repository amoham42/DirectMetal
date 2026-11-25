#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <numeric>
#include <sstream>
#include <string>
#include <vector>

namespace dm {

inline double now_ms() {
    static LARGE_INTEGER freq = [] {
        LARGE_INTEGER f{};
        QueryPerformanceFrequency(&f);
        return f;
    }();
    LARGE_INTEGER counter{};
    QueryPerformanceCounter(&counter);
    return (static_cast<double>(counter.QuadPart) * 1000.0) /
           static_cast<double>(freq.QuadPart);
}

inline uint64_t fnv1a64(const void* data, size_t len) {
    const uint8_t* bytes = static_cast<const uint8_t*>(data);
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < len; ++i) {
        h ^= bytes[i];
        h *= 1099511628211ULL;
    }
    return h;
}

inline std::string hex64(uint64_t v) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::setw(16) << std::setfill('0') << v;
    return oss.str();
}

struct CliOptions {
    std::string out_dir = "out";
    int frames = 200;
    std::string adapter_filter;
};

inline CliOptions parse_cli(int argc, char** argv) {
    CliOptions opts;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--out" && i + 1 < argc) {
            opts.out_dir = argv[++i];
        } else if (arg == "--frames" && i + 1 < argc) {
            opts.frames = std::max(1, std::atoi(argv[++i]));
        } else if (arg == "--adapter" && i + 1 < argc) {
            opts.adapter_filter = argv[++i];
        }
    }
    return opts;
}

inline bool ensure_directory_recursive(const std::string& raw_path) {
    if (raw_path.empty()) return false;
    std::string path = raw_path;
    for (char& c : path) {
        if (c == '/') c = '\\';
    }
    while (path.size() > 3 && path.back() == '\\') {
        path.pop_back();
    }
    for (size_t i = 0; i < path.size(); ++i) {
        if (path[i] == '\\') {
            if (i == 0) continue;
            if (i == 2 && path[1] == ':') continue;
            if (i == 1 && path[0] == '\\') continue;  // UNC prefix
            std::string sub = path.substr(0, i);
            CreateDirectoryA(sub.c_str(), nullptr);
        }
    }
    if (CreateDirectoryA(path.c_str(), nullptr)) {
        return true;
    }
    const DWORD attrs = GetFileAttributesA(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

inline std::string join_path(const std::string& dir, const std::string& file) {
    if (dir.empty()) return file;
    const char back = dir.back();
    if (back == '\\' || back == '/') return dir + file;
    return dir + "\\" + file;
}

inline std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

struct BenchStats {
    int warmup_frames = 0;
    int measured_frames = 0;
    double mean_ms = 0.0;
    double p50_ms = 0.0;
    double p95_ms = 0.0;
    double p99_ms = 0.0;
    double min_ms = 0.0;
    double max_ms = 0.0;
    double total_ms = 0.0;
    double fps = 0.0;
    double one_percent_low_fps = 0.0;
    double gpu_mean_ms = 0.0;
    double extra_ops_per_sec = 0.0;
    std::string extra_metric_name;
};

inline double percentile_sorted(const std::vector<double>& sorted, double p) {
    if (sorted.empty()) return 0.0;
    const double idx = p * static_cast<double>(sorted.size() - 1);
    const size_t lo = static_cast<size_t>(idx);
    const size_t hi = std::min(lo + 1, sorted.size() - 1);
    const double frac = idx - static_cast<double>(lo);
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

inline BenchStats summarize_bench(std::vector<double> samples_ms, int warmup_frames) {
    BenchStats s;
    s.warmup_frames = warmup_frames;
    s.measured_frames = static_cast<int>(samples_ms.size());
    if (samples_ms.empty()) return s;

    std::sort(samples_ms.begin(), samples_ms.end());
    s.total_ms = std::accumulate(samples_ms.begin(), samples_ms.end(), 0.0);
    s.mean_ms = s.total_ms / static_cast<double>(samples_ms.size());
    s.min_ms = samples_ms.front();
    s.max_ms = samples_ms.back();
    s.p50_ms = percentile_sorted(samples_ms, 0.50);
    s.p95_ms = percentile_sorted(samples_ms, 0.95);
    s.p99_ms = percentile_sorted(samples_ms, 0.99);
    s.fps = (s.mean_ms > 0.0) ? (1000.0 / s.mean_ms) : 0.0;

    const size_t slow_count = std::max<size_t>(1, samples_ms.size() / 100);
    double slow_sum = 0.0;
    for (size_t i = samples_ms.size() - slow_count; i < samples_ms.size(); ++i) {
        slow_sum += samples_ms[i];
    }
    const double slow_mean = slow_sum / static_cast<double>(slow_count);
    s.one_percent_low_fps = (slow_mean > 0.0) ? (1000.0 / slow_mean) : 0.0;
    return s;
}

struct TestRecord {
    std::string name;
    std::string status = "fail";
    std::string png_file;
    std::string pixel_checksum;
    bool has_compute_checksum = false;
    std::string compute_checksum;
    std::string expected_compute_checksum;
    std::string shader_model;
    std::string detail;
    double duration_ms = 0.0;
};

struct AdapterMetadata {
    std::string description;
    uint32_t vendor_id = 0;
    uint32_t device_id = 0;
    uint64_t dedicated_vram_mb = 0;
    uint64_t shared_mem_mb = 0;
};

inline bool write_results_json(const std::string& path,
                               const std::string& api_name,
                               const std::string& feature_level,
                               const AdapterMetadata& adapter,
                               const std::vector<TestRecord>& tests,
                               const BenchStats& bench) {
    int passed = 0;
    for (const auto& t : tests) {
        if (t.status == "pass") ++passed;
    }

    std::ostringstream oss;
    oss << std::fixed << std::setprecision(4);
    oss << "{\n";
    oss << "  \"api\": \"" << json_escape(api_name) << "\",\n";
    oss << "  \"feature_level\": \"" << json_escape(feature_level) << "\",\n";
    oss << "  \"adapter\": {\n";
    oss << "    \"description\": \"" << json_escape(adapter.description) << "\",\n";
    oss << "    \"vendor_id\": " << adapter.vendor_id << ",\n";
    oss << "    \"device_id\": " << adapter.device_id << ",\n";
    oss << "    \"dedicated_vram_mb\": " << adapter.dedicated_vram_mb << ",\n";
    oss << "    \"shared_mem_mb\": " << adapter.shared_mem_mb << "\n";
    oss << "  },\n";
    oss << "  \"summary\": {\n";
    oss << "    \"passed\": " << passed << ",\n";
    oss << "    \"total\": " << tests.size() << "\n";
    oss << "  },\n";
    oss << "  \"tests\": [\n";
    for (size_t i = 0; i < tests.size(); ++i) {
        const auto& t = tests[i];
        oss << "    {\n";
        oss << "      \"name\": \"" << json_escape(t.name) << "\",\n";
        oss << "      \"status\": \"" << json_escape(t.status) << "\",\n";
        oss << "      \"png\": \"" << json_escape(t.png_file) << "\",\n";
        oss << "      \"pixel_checksum\": \"" << json_escape(t.pixel_checksum) << "\",\n";
        if (t.has_compute_checksum) {
            oss << "      \"compute_checksum\": \"" << json_escape(t.compute_checksum) << "\",\n";
            oss << "      \"expected_compute_checksum\": \"" << json_escape(t.expected_compute_checksum) << "\",\n";
        }
        if (!t.shader_model.empty()) {
            oss << "      \"shader_model\": \"" << json_escape(t.shader_model) << "\",\n";
        }
        oss << "      \"duration_ms\": " << t.duration_ms << ",\n";
        oss << "      \"detail\": \"" << json_escape(t.detail) << "\"\n";
        oss << "    }" << (i + 1 < tests.size() ? "," : "") << "\n";
    }
    oss << "  ],\n";
    oss << "  \"benchmark\": {\n";
    oss << "    \"name\": \"" << (api_name == "D3D11" ? "d3d11_bench_frame" : "d3d12_bench_frame") << "\",\n";
    oss << "    \"warmup_frames\": " << bench.warmup_frames << ",\n";
    oss << "    \"measured_frames\": " << bench.measured_frames << ",\n";
    oss << "    \"mean_ms\": " << bench.mean_ms << ",\n";
    oss << "    \"p50_ms\": " << bench.p50_ms << ",\n";
    oss << "    \"p95_ms\": " << bench.p95_ms << ",\n";
    oss << "    \"p99_ms\": " << bench.p99_ms << ",\n";
    oss << "    \"min_ms\": " << bench.min_ms << ",\n";
    oss << "    \"max_ms\": " << bench.max_ms << ",\n";
    oss << "    \"fps\": " << bench.fps << ",\n";
    oss << "    \"one_percent_low_fps\": " << bench.one_percent_low_fps << ",\n";
    oss << "    \"gpu_mean_ms\": " << bench.gpu_mean_ms << ",\n";
    oss << "    \"extra_metric_name\": \"" << json_escape(bench.extra_metric_name) << "\",\n";
    oss << "    \"extra_ops_per_sec\": " << bench.extra_ops_per_sec << "\n";
    oss << "  }\n";
    oss << "}\n";

    std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
    if (!ofs.is_open()) return false;
    const std::string data = oss.str();
    ofs.write(data.data(), static_cast<std::streamsize>(data.size()));
    return ofs.good();
}

}  // namespace dm
