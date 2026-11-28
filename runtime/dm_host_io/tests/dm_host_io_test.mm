#include "dm_host_io.h"

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_host_io_test] CHECK FAILED (%s:%d): %s\n",            \
                    __FILE__, __LINE__, #expr);                                        \
            std::abort();                                                              \
        }                                                                              \
    } while (0)

static std::string json_escape(const char *s) {
    if (!s) return "";
    std::string out;
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(s); *p; ++p) {
        switch (*p) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (*p >= 0x20) {
                    out.push_back(static_cast<char>(*p));
                }
                break;
        }
    }
    return out;
}

static bool write_json_report(const char *path,
                              const dm_audio_probe_result_t &audio,
                              const dm_input_probe_result_t &input) {
    if (!path || !path[0]) return false;
    FILE *jf = fopen(path, "w");
    if (!jf) return false;
    const std::string esc_dev = json_escape(audio.device_name);
    const int rc = fprintf(jf,
                           "{\n"
                           "  \"arch\": \"arm64\",\n"
                           "  \"audio_has_output\": %s,\n"
                           "  \"audio_device\": \"%s\",\n"
                           "  \"audio_sample_rate_hz\": %.1f,\n"
                           "  \"audio_buffer_frames\": %u,\n"
                           "  \"audio_latency_ms\": %.3f,\n"
                           "  \"gamecontroller_ok\": %s,\n"
                           "  \"connected_controllers\": %u\n"
                           "}\n",
                           audio.has_default_output ? "true" : "false",
                           esc_dev.c_str(),
                           audio.sample_rate_hz,
                           audio.buffer_frames,
                           audio.hardware_latency_ms,
                           input.gamecontroller_framework_ok ? "true" : "false",
                           input.connected_controllers);
    const int close_rc = fclose(jf);
    return rc > 0 && close_rc == 0;
}

static void verify_audio_invariants(const dm_audio_probe_result_t &audio) {
    const void *nul_pos = std::memchr(audio.device_name, '\0', sizeof(audio.device_name));
    DM_CHECK(nul_pos != nullptr);
    const size_t name_len = std::strlen(audio.device_name);
    DM_CHECK(name_len > 0 && name_len < sizeof(audio.device_name));
    DM_CHECK(std::isfinite(audio.sample_rate_hz) && audio.sample_rate_hz >= 0.0);
    DM_CHECK(std::isfinite(audio.hardware_latency_ms) && audio.hardware_latency_ms >= 0.0);

    const unsigned char raw_has_out = *reinterpret_cast<const unsigned char *>(&audio.has_default_output);
    DM_CHECK(raw_has_out <= 1u);

    if (!audio.has_default_output) {
        DM_CHECK(std::strcmp(audio.device_name, "No Audio Output Device") == 0);
        DM_CHECK(audio.sample_rate_hz == 0.0);
        DM_CHECK(audio.buffer_frames == 0u);
        DM_CHECK(audio.safety_offset_frames == 0u);
        DM_CHECK(audio.hardware_latency_ms == 0.0);
    } else if (audio.sample_rate_hz > 0.0) {
        const double total_frames =
            static_cast<double>(static_cast<uint64_t>(audio.buffer_frames) +
                                static_cast<uint64_t>(audio.safety_offset_frames));
        const double expected_ms = (total_frames * 1000.0) / audio.sample_rate_hz;
        DM_CHECK(std::fabs(audio.hardware_latency_ms - expected_ms) < 1e-6);
    } else {
        DM_CHECK(audio.hardware_latency_ms == 0.0);
    }
}

static void verify_input_invariants(const dm_input_probe_result_t &input) {
    const unsigned char raw_kb = *reinterpret_cast<const unsigned char *>(&input.has_coalesced_keyboard);
    const unsigned char raw_ms = *reinterpret_cast<const unsigned char *>(&input.has_coalesced_mouse);
    const unsigned char raw_ok = *reinterpret_cast<const unsigned char *>(&input.gamecontroller_framework_ok);
    DM_CHECK(raw_kb <= 1u);
    DM_CHECK(raw_ms <= 1u);
    DM_CHECK(raw_ok == 1u);
    DM_CHECK(input.gamecontroller_framework_ok);
}

static void test_null_and_poisoned_buffers(void) {
    // NULL output pointers must fail cleanly
    DM_CHECK(!dm_audio_probe(nullptr));
    DM_CHECK(!dm_input_probe(nullptr));

    // Poisoned memory buffers must be completely sanitized on probe
    dm_audio_probe_result_t poisoned_audio;
    std::memset(&poisoned_audio, 0xA5, sizeof(poisoned_audio));
    DM_CHECK(dm_audio_probe(&poisoned_audio));
    verify_audio_invariants(poisoned_audio);

    dm_input_probe_result_t poisoned_input;
    std::memset(&poisoned_input, 0xFF, sizeof(poisoned_input));
    DM_CHECK(dm_input_probe(&poisoned_input));
    verify_input_invariants(poisoned_input);
}

static void test_json_and_host_io_boundaries(const dm_audio_probe_result_t &audio,
                                             const dm_input_probe_result_t &input) {
    // NULL and empty string handling
    DM_CHECK(json_escape(nullptr).empty());
    DM_CHECK(json_escape("").empty());
    DM_CHECK(json_escape("a\"b\\c\nd\re\tf\x01\x1fZ") == "a\\\"b\\\\c\\nd\\re\\tfZ");

    // Maximum device_name boundary length (255 chars + NUL)
    char max_name[sizeof(audio.device_name)];
    std::memset(max_name, 'X', sizeof(max_name) - 1);
    max_name[sizeof(max_name) - 1] = '\0';
    const std::string esc_max = json_escape(max_name);
    DM_CHECK(esc_max.size() == sizeof(max_name) - 1);

    // Nonexistent paths, empty paths, and overlong path boundary cases
    DM_CHECK(!write_json_report(nullptr, audio, input));
    DM_CHECK(!write_json_report("", audio, input));
    DM_CHECK(!write_json_report("/nonexistent_dm_host_io_dir_999/sub/out.json", audio, input));

    std::string overlong_path("/tmp/");
    overlong_path.append(4096, 'p');
    overlong_path.append("/report.json");
    DM_CHECK(!write_json_report(overlong_path.c_str(), audio, input));

    // Invalid file descriptor edge cases (-1 and closed fd)
    char dummy[16] = {0};
    DM_CHECK(read(-1, dummy, sizeof(dummy)) < 0);
    DM_CHECK(write(-1, "x", 1) < 0);
    DM_CHECK(close(-1) < 0);

    int pipe_fds[2] = {-1, -1};
    DM_CHECK(pipe(pipe_fds) == 0);
    const int closed_fd = pipe_fds[0];
    DM_CHECK(close(pipe_fds[0]) == 0);
    DM_CHECK(close(pipe_fds[1]) == 0);
    DM_CHECK(read(closed_fd, dummy, sizeof(dummy)) < 0);

    // Temporary report open-write-read-close cycle & zero-length read check
    char tmp_tmpl[] = "/tmp/dm_host_io_report_XXXXXX";
    const int tmp_fd = mkstemp(tmp_tmpl);
    DM_CHECK(tmp_fd >= 0);
    DM_CHECK(close(tmp_fd) == 0);

    DM_CHECK(write_json_report(tmp_tmpl, audio, input));

    const int rd_fd = open(tmp_tmpl, O_RDONLY);
    DM_CHECK(rd_fd >= 0);
    DM_CHECK(read(rd_fd, dummy, 0) == 0);  // zero-length buffer read must return 0

    std::string file_contents;
    char chunk[256];
    for (;;) {
        const ssize_t n = read(rd_fd, chunk, sizeof(chunk));
        DM_CHECK(n >= 0);
        if (n == 0) break;
        file_contents.append(chunk, static_cast<size_t>(n));
    }
    DM_CHECK(close(rd_fd) == 0);
    DM_CHECK(unlink(tmp_tmpl) == 0);
    DM_CHECK(open(tmp_tmpl, O_RDONLY) < 0);  // unlinked path must fail open

    DM_CHECK(file_contents.find("\"arch\": \"arm64\"") != std::string::npos);
    DM_CHECK(file_contents.find("\"gamecontroller_ok\": true") != std::string::npos);
}

static void test_repeated_and_concurrent_probes(void) {
    // Repeated sequential probes (checks autoreleasepool & CFStringRef lifecycle)
    for (int i = 0; i < 64; ++i) {
        dm_audio_probe_result_t a;
        dm_input_probe_result_t in;
        std::memset(&a, 0x5A, sizeof(a));
        std::memset(&in, 0x5A, sizeof(in));
        DM_CHECK(dm_audio_probe(&a));
        DM_CHECK(dm_input_probe(&in));
        verify_audio_invariants(a);
        verify_input_invariants(in);
    }

    // Concurrent multi-threaded audio & input probes
    constexpr int kThreads = 4;
    constexpr int kItersPerThread = 16;
    std::atomic<int> failures{0};
    std::vector<std::thread> workers;
    workers.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        workers.emplace_back([&failures]() {
            for (int i = 0; i < kItersPerThread; ++i) {
                dm_audio_probe_result_t a{};
                dm_input_probe_result_t in{};
                if (!dm_audio_probe(&a) || !dm_input_probe(&in) || !in.gamecontroller_framework_ok) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                if (std::memchr(a.device_name, '\0', sizeof(a.device_name)) == nullptr ||
                    std::strlen(a.device_name) == 0 ||
                    !std::isfinite(a.sample_rate_hz) ||
                    !std::isfinite(a.hardware_latency_ms)) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
            }
        });
    }
    for (auto &th : workers) {
        th.join();
    }
    DM_CHECK(failures.load(std::memory_order_relaxed) == 0);
}

int main(int argc, char **argv) {
#if !defined(__aarch64__)
#error "dm_host_io_test must compile as native arm64 on Apple Silicon"
#endif
    const char *json_path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--json") == 0 && i + 1 < argc) {
            json_path = argv[++i];
        }
    }

    test_null_and_poisoned_buffers();

    dm_audio_probe_result_t audio{};
    DM_CHECK(dm_audio_probe(&audio));
    verify_audio_invariants(audio);

    dm_input_probe_result_t input{};
    DM_CHECK(dm_input_probe(&input));
    verify_input_invariants(input);

    test_json_and_host_io_boundaries(audio, input);
    test_repeated_and_concurrent_probes();

    printf("[dm_host_io_test] Arch: arm64 native\n");
    printf("[dm_host_io_test] CoreAudio: output=%s device=\"%s\" rate=%.0f Hz buf=%u frames safety=%u latency=%.2f ms\n",
           audio.has_default_output ? "yes" : "none",
           audio.device_name,
           audio.sample_rate_hz,
           audio.buffer_frames,
           audio.safety_offset_frames,
           audio.hardware_latency_ms);
    printf("[dm_host_io_test] GameController.framework: ok=%s controllers=%u keyboard=%s mouse=%s\n",
           input.gamecontroller_framework_ok ? "yes" : "no",
           input.connected_controllers,
           input.has_coalesced_keyboard ? "yes" : "no",
           input.has_coalesced_mouse ? "yes" : "no");
    printf("[dm_host_io_test] PASSED: edge-case, boundary, file/fd & concurrent probe checks.\n");

    if (json_path) {
        DM_CHECK(write_json_report(json_path, audio, input));
    }
    return 0;
}
