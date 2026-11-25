#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dm_audio_probe_result {
    bool has_default_output;
    char device_name[256];
    double sample_rate_hz;
    uint32_t buffer_frames;
    uint32_t safety_offset_frames;
    double hardware_latency_ms;
} dm_audio_probe_result_t;

typedef struct dm_input_probe_result {
    uint32_t connected_controllers;
    bool has_coalesced_keyboard;
    bool has_coalesced_mouse;
    bool gamecontroller_framework_ok;
} dm_input_probe_result_t;

bool dm_audio_probe(dm_audio_probe_result_t *out);
bool dm_input_probe(dm_input_probe_result_t *out);

#ifdef __cplusplus
}
#endif
