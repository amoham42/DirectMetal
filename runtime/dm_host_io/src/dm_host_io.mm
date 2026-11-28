#include "dm_host_io.h"

#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include <cmath>
#include <cstdio>
#include <cstring>

bool dm_audio_probe(dm_audio_probe_result_t *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));

    @autoreleasepool {
        AudioDeviceID dev_id = kAudioObjectUnknown;
        UInt32 size = sizeof(dev_id);
        AudioObjectPropertyAddress dev_addr = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };

        OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &dev_addr, 0, NULL, &size, &dev_id);
        if (st != noErr || dev_id == kAudioObjectUnknown) {
            snprintf(out->device_name, sizeof(out->device_name), "No Audio Output Device");
            return true;  // Probe succeeded; headless or no audio output attached
        }
        out->has_default_output = true;

        CFStringRef name_ref = NULL;
        size = sizeof(name_ref);
        AudioObjectPropertyAddress name_addr = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        const OSStatus name_st = AudioObjectGetPropertyData(dev_id, &name_addr, 0, NULL, &size, &name_ref);
        if (name_st == noErr && name_ref) {
            NSString *ns_name = (__bridge NSString *)name_ref;
            const char *utf8 = ns_name ? ns_name.UTF8String : NULL;
            snprintf(out->device_name, sizeof(out->device_name), "%s",
                     (utf8 && utf8[0]) ? utf8 : "Apple CoreAudio Device");
        } else {
            snprintf(out->device_name, sizeof(out->device_name), "Apple CoreAudio Device");
        }
        if (name_ref) {
            CFRelease(name_ref);
            name_ref = NULL;
        }

        Float64 sample_rate = 0.0;
        size = sizeof(sample_rate);
        AudioObjectPropertyAddress sr_addr = {
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(dev_id, &sr_addr, 0, NULL, &size, &sample_rate) == noErr &&
            std::isfinite(sample_rate) && sample_rate > 0.0) {
            out->sample_rate_hz = sample_rate;
        }

        UInt32 frames = 0;
        size = sizeof(frames);
        AudioObjectPropertyAddress buf_addr = {
            kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(dev_id, &buf_addr, 0, NULL, &size, &frames) == noErr) {
            out->buffer_frames = frames;
        }

        UInt32 safety = 0;
        size = sizeof(safety);
        AudioObjectPropertyAddress safe_addr = {
            kAudioDevicePropertySafetyOffset,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(dev_id, &safe_addr, 0, NULL, &size, &safety) == noErr) {
            out->safety_offset_frames = safety;
        }

        if (out->sample_rate_hz > 0.0) {
            const uint64_t total_frames =
                static_cast<uint64_t>(out->buffer_frames) + static_cast<uint64_t>(out->safety_offset_frames);
            out->hardware_latency_ms = (static_cast<double>(total_frames) * 1000.0) / out->sample_rate_hz;
        }
        return true;
    }
}

bool dm_input_probe(dm_input_probe_result_t *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    @autoreleasepool {
        NSArray<GCController *> *controllers = [GCController controllers];
        out->connected_controllers = controllers ? (uint32_t)controllers.count : 0u;
        out->has_coalesced_keyboard = ([GCKeyboard coalescedKeyboard] != nil);
        NSArray<GCMouse *> *mice = [GCMouse mice];
        out->has_coalesced_mouse = ([GCMouse current] != nil || (mice && mice.count > 0));
        out->gamecontroller_framework_ok = true;
        return true;
    }
}
