#include "dm_host_io.h"

#include <cstdio>
#include <cstring>
#include <string>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_host_io_test] CHECK FAILED (%s:%d): %s\n",            \
                    __FILE__, __LINE__, #expr);                                        \
            return 1;                                                                  \
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

    DM_CHECK(!dm_audio_probe(nullptr));
    DM_CHECK(!dm_input_probe(nullptr));

    dm_audio_probe_result_t audio{};
    DM_CHECK(dm_audio_probe(&audio));

    dm_input_probe_result_t input{};
    DM_CHECK(dm_input_probe(&input));
    DM_CHECK(input.gamecontroller_framework_ok);

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

    if (json_path) {
        FILE *jf = fopen(json_path, "w");
        DM_CHECK(jf != nullptr);
        const std::string esc_dev = json_escape(audio.device_name);
        fprintf(jf,
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
        fclose(jf);
    }
    return 0;
}
