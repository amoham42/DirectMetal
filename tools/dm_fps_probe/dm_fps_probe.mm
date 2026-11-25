#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct FrameSample {
    double host_ts_s;
    double frame_dt_ms;
    uint32_t width;
    uint32_t height;
};

struct ProbeState {
    std::mutex mu;
    std::vector<FrameSample> samples;
    std::vector<double> gpu_times_ms;
    double last_present_ts = 0.0;
    uint64_t total_presents = 0;
    uint64_t metalfx_spatial_calls = 0;
    uint64_t metalfx_temporal_calls = 0;
    std::string out_path;
    bool initialized = false;
};

ProbeState& state() {
    static ProbeState* s = new ProbeState();
    return *s;
}

static void flush_report_locked(ProbeState& s) {
    if (s.out_path.empty() || s.total_presents == 0) return;

    std::vector<double> dts;
    dts.reserve(s.samples.size());
    uint32_t last_w = 0, last_h = 0;
    for (const auto& f : s.samples) {
        if (f.frame_dt_ms > 0.0 && f.frame_dt_ms < 5000.0) {
            dts.push_back(f.frame_dt_ms);
        }
        if (f.width > 0) { last_w = f.width; last_h = f.height; }
    }

    double mean_dt = 0.0, p50_dt = 0.0, p95_dt = 0.0, p99_dt = 0.0, low1_fps = 0.0, mean_fps = 0.0;
    if (!dts.empty()) {
        std::sort(dts.begin(), dts.end());
        double sum = 0.0;
        for (double v : dts) sum += v;
        mean_dt = sum / dts.size();
        mean_fps = mean_dt > 0.0 ? (1000.0 / mean_dt) : 0.0;
        p50_dt = dts[dts.size() / 2];
        p95_dt = dts[std::min(dts.size() - 1, (size_t)(dts.size() * 0.95))];
        p99_dt = dts[std::min(dts.size() - 1, (size_t)(dts.size() * 0.99))];
        size_t tail_count = std::max<size_t>(1, dts.size() / 100);
        double slow_sum = 0.0;
        for (size_t i = dts.size() - tail_count; i < dts.size(); ++i) slow_sum += dts[i];
        double slow_mean = slow_sum / tail_count;
        low1_fps = slow_mean > 0.0 ? (1000.0 / slow_mean) : 0.0;
    }

    double mean_gpu = 0.0;
    if (!s.gpu_times_ms.empty()) {
        double gsum = 0.0;
        for (double v : s.gpu_times_ms) gsum += v;
        mean_gpu = gsum / s.gpu_times_ms.size();
    }

    std::string tmp = s.out_path + "." + std::to_string(getpid()) + ".tmp";
    FILE* fp = std::fopen(tmp.c_str(), "w");
    if (!fp) return;
    std::fprintf(fp,
        "{\n"
        "  \"pid\": %d,\n"
        "  \"total_presents\": %llu,\n"
        "  \"sampled_intervals\": %zu,\n"
        "  \"drawable_width\": %u,\n"
        "  \"drawable_height\": %u,\n"
        "  \"mean_fps\": %.2f,\n"
        "  \"low_1pct_fps\": %.2f,\n"
        "  \"mean_frame_ms\": %.3f,\n"
        "  \"p50_frame_ms\": %.3f,\n"
        "  \"p95_frame_ms\": %.3f,\n"
        "  \"p99_frame_ms\": %.3f,\n"
        "  \"mean_gpu_ms\": %.3f,\n"
        "  \"metalfx_spatial_calls\": %llu,\n"
        "  \"metalfx_temporal_calls\": %llu\n"
        "}\n",
        (int)getpid(),
        (unsigned long long)s.total_presents,
        dts.size(),
        last_w, last_h,
        mean_fps, low1_fps,
        mean_dt, p50_dt, p95_dt, p99_dt,
        mean_gpu,
        (unsigned long long)s.metalfx_spatial_calls,
        (unsigned long long)s.metalfx_temporal_calls
    );
    std::fclose(fp);
    std::rename(tmp.c_str(), s.out_path.c_str());
}

static IMP orig_nextDrawable = nullptr;

static void try_hook_metalfx_classes() {
    static std::atomic<int> scans{0};
    if (scans.fetch_add(1) > 4) return;
    int numClasses = objc_getClassList(nullptr, 0);
    if (numClasses <= 0) return;
    std::vector<Class> classes(numClasses);
    numClasses = objc_getClassList(classes.data(), numClasses);
    SEL encSel = @selector(encodeToCommandBuffer:);
    for (int i = 0; i < numClasses; ++i) {
        Class cls = classes[i];
        const char* name = class_getName(cls);
        if (!name) continue;
        bool isSpatial = (std::strstr(name, "FXSpatialScaler") != nullptr) && !std::strstr(name, "Descriptor");
        bool isTemporal = (std::strstr(name, "FXTemporalScaler") != nullptr) && !std::strstr(name, "Descriptor");
        if (!isSpatial && !isTemporal) continue;
        Method m = class_getInstanceMethod(cls, encSel);
        if (!m) continue;
        static std::mutex hook_mu;
        static std::vector<Class> hooked_classes;
        std::lock_guard<std::mutex> lk(hook_mu);
        if (std::find(hooked_classes.begin(), hooked_classes.end(), cls) != hooked_classes.end()) continue;
        hooked_classes.push_back(cls);
        IMP orig = method_getImplementation(m);
        IMP repl = imp_implementationWithBlock(^(id selfObj, id cmdBuf) {
            auto& s = state();
            {
                std::lock_guard<std::mutex> slk(s.mu);
                if (isSpatial) s.metalfx_spatial_calls++;
                else s.metalfx_temporal_calls++;
            }
            ((void (*)(id, SEL, id))orig)(selfObj, encSel, cmdBuf);
        });
        method_setImplementation(m, repl);
    }
}

static id hooked_nextDrawable(id self, SEL _cmd) {
    id<CAMetalDrawable> drawable = ((id (*)(id, SEL))orig_nextDrawable)(self, _cmd);
    if (drawable) {
        double now = CACurrentMediaTime();
        uint32_t w = 0, h = 0;
        id<MTLTexture> tex = [drawable texture];
        if (tex) {
            w = (uint32_t)[tex width];
            h = (uint32_t)[tex height];
        }
        auto& s = state();
        std::lock_guard<std::mutex> lk(s.mu);
        s.total_presents++;
        if (s.total_presents == 1 || s.total_presents == 10) {
            try_hook_metalfx_classes();
        }
        double dt_ms = 0.0;
        if (s.last_present_ts > 0.0) {
            dt_ms = (now - s.last_present_ts) * 1000.0;
        }
        s.last_present_ts = now;
        // Skip initial 15 warmup frames when computing steady-state frame times
        if (s.total_presents > 15 && dt_ms > 0.0) {
            s.samples.push_back({now, dt_ms, w, h});
        }
        if (s.total_presents == 5 || (s.total_presents % 15) == 0) {
            flush_report_locked(s);
        }
    }
    return drawable;
}

static void on_exit_flush() {
    auto& s = state();
    std::lock_guard<std::mutex> lk(s.mu);
    flush_report_locked(s);
}

__attribute__((constructor))
static void dm_fps_probe_init() {
    const char* out = std::getenv("DM_FPS_PROBE_OUT");
    if (!out || !out[0]) return;
    auto& s = state();
    {
        std::lock_guard<std::mutex> lk(s.mu);
        s.out_path = out;
        s.initialized = true;
    }
    Class layerCls = objc_getClass("CAMetalLayer");
    if (layerCls) {
        Method m = class_getInstanceMethod(layerCls, @selector(nextDrawable));
        if (m) {
            orig_nextDrawable = method_setImplementation(m, (IMP)hooked_nextDrawable);
        }
    }
    try_hook_metalfx_classes();
    std::atexit(on_exit_flush);
}

} // namespace
