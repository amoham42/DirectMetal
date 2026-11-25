#include "dm_host_io.h"

#include <assert.h>
#include <cstdio>
#include <cstring>

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

    dm_audio_probe_result_t audio{};
    assert(dm_audio_probe(&audio));

    dm_input_probe_result_t input{};
    assert(dm_input_probe(&input));
    assert(input.gamecontroller_framework_ok);

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
        assert(jf != nullptr);
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
                audio.device_name,
                audio.sample_rate_hz,
                audio.buffer_frames,
                audio.hardware_latency_ms,
                input.gamecontroller_framework_ok ? "true" : "false",
                input.connected_controllers);
        fclose(jf);
    }
    return 0;
}
