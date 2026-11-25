#include "dm_host_io.h"

#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include <cstdio>
#include <cstring>

bool dm_audio_probe(dm_audio_probe_result_t *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));

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
    if (AudioObjectGetPropertyData(dev_id, &name_addr, 0, NULL, &size, &name_ref) == noErr && name_ref) {
        CFStringGetCString(name_ref, out->device_name, sizeof(out->device_name), kCFStringEncodingUTF8);
        CFRelease(name_ref);
    } else {
        snprintf(out->device_name, sizeof(out->device_name), "Apple CoreAudio Device");
    }

    Float64 sample_rate = 0.0;
    size = sizeof(sample_rate);
    AudioObjectPropertyAddress sr_addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(dev_id, &sr_addr, 0, NULL, &size, &sample_rate) == noErr) {
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
        out->hardware_latency_ms =
            ((double)(out->buffer_frames + out->safety_offset_frames) * 1000.0) / out->sample_rate_hz;
    }
    return true;
}

bool dm_input_probe(dm_input_probe_result_t *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));
    @autoreleasepool {
        NSArray<GCController *> *controllers = [GCController controllers];
        out->connected_controllers = (uint32_t)controllers.count;
        out->has_coalesced_keyboard = ([GCKeyboard coalescedKeyboard] != nil);
        out->has_coalesced_mouse = ([GCMouse current] != nil || [GCMouse mice].count > 0);
        out->gamecontroller_framework_ok = true;
        return true;
    }
}
