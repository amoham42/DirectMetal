#include "dm_shader_cache.h"
#include "dm_metal_core.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

struct dm_shader_cache {
    id<MTLDevice> device;
    id<MTLBinaryArchive> archive;
    dm_shader_cache_stats_t stats;
};

static bool mkdir_p(const std::string &path) {
    if (path.empty()) return false;
    std::string cur;
    cur.reserve(path.size());
    for (size_t i = 0; i < path.size(); ++i) {
        cur.push_back(path[i]);
        if (path[i] == '/' && cur.size() > 1) {
            mkdir(cur.c_str(), 0755);
        }
    }
    if (mkdir(path.c_str(), 0755) != 0 && errno != EEXIST) {
        return false;
    }
    struct stat st{};
    return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

static void set_err_msg(char *buf, size_t cap, const char *msg) {
    if (!buf || cap == 0) return;
    snprintf(buf, cap, "%s", msg ? msg : "unknown shader cache error");
}

static void copy_err(NSError *err, char *buf, size_t cap, const char *fallback) {
    if (!buf || cap == 0) return;
    if (err && err.localizedDescription && err.localizedDescription.UTF8String) {
        snprintf(buf, cap, "%s", err.localizedDescription.UTF8String);
    } else {
        snprintf(buf, cap, "%s", fallback ? fallback : "unknown Metal archive error");
    }
}

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

dm_shader_cache_t *dm_shader_cache_open(const char *cache_root,
                                        const char *game_build_id,
                                        char *err_buf,
                                        size_t err_cap) {
    if (err_buf && err_cap > 0) {
        err_buf[0] = '\0';
    }
    if (!cache_root || !game_build_id || !cache_root[0] || !game_build_id[0]) {
        set_err_msg(err_buf, err_cap, "Invalid cache_root or game_build_id");
        return nullptr;
    }
    if (std::strstr(game_build_id, "..") != nullptr ||
        std::strchr(game_build_id, '/') != nullptr ||
        std::strchr(game_build_id, '\\') != nullptr) {
        set_err_msg(err_buf, err_cap, "Invalid path characters in game_build_id");
        return nullptr;
    }

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            set_err_msg(err_buf, err_cap, "MTLCreateSystemDefaultDevice returned nil");
            return nullptr;
        }

        dm_metal_device_info_t info{};
        if (!dm_metal_query_device(&info)) {
            set_err_msg(err_buf, err_cap, "dm_metal_query_device failed");
            return nullptr;
        }

        const int metal_major = info.supports_metal4 ? 4 : 3;
        char cache_key[192];
        const int key_len = snprintf(cache_key, sizeof(cache_key), "%s_%s_m%d",
                                     game_build_id, info.cache_key, metal_major);
        if (key_len < 0 || static_cast<size_t>(key_len) >= sizeof(cache_key)) {
            set_err_msg(err_buf, err_cap, "cache_key exceeds maximum length");
            return nullptr;
        }

        std::string dir = std::string(cache_root) + "/" + cache_key;
        std::string archive_path = dir + "/pipelines.metallibarchive";
        std::string manifest_path = dir + "/manifest.json";
        if (archive_path.size() >= sizeof(((dm_shader_cache_stats_t *)0)->archive_path) ||
            manifest_path.size() >= sizeof(((dm_shader_cache_stats_t *)0)->manifest_path)) {
            set_err_msg(err_buf, err_cap, "Shader cache path exceeds buffer capacity");
            return nullptr;
        }

        if (!mkdir_p(dir)) {
            if (err_buf && err_cap > 0) {
                snprintf(err_buf, err_cap, "Failed to create cache dir %s", dir.c_str());
            }
            return nullptr;
        }

        struct stat st{};
        bool loaded_existing = (stat(archive_path.c_str(), &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0);

        MTLBinaryArchiveDescriptor *bad = [MTLBinaryArchiveDescriptor new];
        if (!bad) {
            set_err_msg(err_buf, err_cap, "Failed to allocate MTLBinaryArchiveDescriptor");
            return nullptr;
        }
        if (loaded_existing) {
            NSString *ns_archive = [NSString stringWithUTF8String:archive_path.c_str()];
            if (!ns_archive) {
                set_err_msg(err_buf, err_cap, "Invalid UTF-8 in archive_path");
                return nullptr;
            }
            bad.url = [NSURL fileURLWithPath:ns_archive];
        } else {
            bad.url = nil;
        }

        NSError *err = nil;
        id<MTLBinaryArchive> arch = [dev newBinaryArchiveWithDescriptor:bad error:&err];
        if (!arch && loaded_existing) {
            // Fall back to fresh archive if OS/GPU invalidated existing archive
            loaded_existing = false;
            bad.url = nil;
            err = nil;
            arch = [dev newBinaryArchiveWithDescriptor:bad error:&err];
        }
        if (!arch) {
            copy_err(err, err_buf, err_cap, "newBinaryArchiveWithDescriptor failed");
            return nullptr;
        }

        auto *cache = new (std::nothrow) dm_shader_cache();
        if (!cache) {
            set_err_msg(err_buf, err_cap, "Out of memory allocating dm_shader_cache");
            return nullptr;
        }
        cache->device = dev;
        cache->archive = arch;
        memset(&cache->stats, 0, sizeof(cache->stats));
        snprintf(cache->stats.cache_key, sizeof(cache->stats.cache_key), "%s", cache_key);
        snprintf(cache->stats.archive_path, sizeof(cache->stats.archive_path), "%s", archive_path.c_str());
        snprintf(cache->stats.manifest_path, sizeof(cache->stats.manifest_path), "%s", manifest_path.c_str());
        cache->stats.loaded_existing = loaded_existing;
        cache->stats.archive_bytes = loaded_existing ? static_cast<uint64_t>(st.st_size) : 0;
        return cache;
    }
}

void dm_shader_cache_close(dm_shader_cache_t *cache) {
    if (!cache) return;
    @autoreleasepool {
        cache->archive = nil;
        cache->device = nil;
    }
    delete cache;
}

bool dm_shader_cache_add_render_pso(dm_shader_cache_t *cache,
                                    void *mtl_render_pipeline_desc,
                                    char *err_buf,
                                    size_t err_cap) {
    if (!cache || !cache->archive || !mtl_render_pipeline_desc) {
        set_err_msg(err_buf, err_cap, "Invalid cache or render pipeline descriptor");
        return false;
    }
    @autoreleasepool {
        MTLRenderPipelineDescriptor *rpd = (__bridge MTLRenderPipelineDescriptor *)mtl_render_pipeline_desc;
        NSError *err = nil;
        BOOL ok = [cache->archive addRenderPipelineFunctionsWithDescriptor:rpd error:&err];
        if (!ok) {
            copy_err(err, err_buf, err_cap, "addRenderPipelineFunctionsWithDescriptor failed");
            return false;
        }
        cache->stats.pipelines_cached += 1;
        return true;
    }
}

bool dm_shader_cache_add_compute_pso(dm_shader_cache_t *cache,
                                     void *mtl_compute_pipeline_desc,
                                     char *err_buf,
                                     size_t err_cap) {
    if (!cache || !cache->archive || !mtl_compute_pipeline_desc) {
        set_err_msg(err_buf, err_cap, "Invalid cache or compute pipeline descriptor");
        return false;
    }
    @autoreleasepool {
        MTLComputePipelineDescriptor *cpd = (__bridge MTLComputePipelineDescriptor *)mtl_compute_pipeline_desc;
        NSError *err = nil;
        BOOL ok = [cache->archive addComputePipelineFunctionsWithDescriptor:cpd error:&err];
        if (!ok) {
            copy_err(err, err_buf, err_cap, "addComputePipelineFunctionsWithDescriptor failed");
            return false;
        }
        cache->stats.pipelines_cached += 1;
        return true;
    }
}

bool dm_shader_cache_flush(dm_shader_cache_t *cache, char *err_buf, size_t err_cap) {
    if (!cache || !cache->archive) {
        set_err_msg(err_buf, err_cap, "Invalid shader cache handle");
        return false;
    }
    @autoreleasepool {
        std::string tmp_path = std::string(cache->stats.archive_path) + ".tmp";
        unlink(tmp_path.c_str());

        NSString *ns_tmp = [NSString stringWithUTF8String:tmp_path.c_str()];
        if (!ns_tmp) {
            set_err_msg(err_buf, err_cap, "Invalid UTF-8 in temporary archive path");
            return false;
        }
        NSURL *tmp_url = [NSURL fileURLWithPath:ns_tmp];
        NSError *err = nil;
        if (![cache->archive serializeToURL:tmp_url error:&err]) {
            unlink(tmp_path.c_str());
            copy_err(err, err_buf, err_cap, "serializeToURL failed");
            return false;
        }
        if (rename(tmp_path.c_str(), cache->stats.archive_path) != 0) {
            const int saved_errno = errno;
            unlink(tmp_path.c_str());
            if (err_buf && err_cap > 0) {
                snprintf(err_buf, err_cap, "rename failed: %s", std::strerror(saved_errno));
            }
            return false;
        }
        struct stat st{};
        if (stat(cache->stats.archive_path, &st) == 0 && st.st_size >= 0) {
            cache->stats.archive_bytes = static_cast<uint64_t>(st.st_size);
        }

        dm_metal_device_info_t info{};
        dm_metal_query_device(&info);
        FILE *mf = fopen(cache->stats.manifest_path, "w");
        if (mf) {
            const std::string esc_key = json_escape(cache->stats.cache_key);
            const std::string esc_gpu = json_escape(info.gpu_name);
            const std::string esc_fam = json_escape(info.gpu_family);
            const std::string esc_bld = json_escape(info.macos_build);
            fprintf(mf,
                    "{\n"
                    "  \"cache_key\": \"%s\",\n"
                    "  \"gpu_name\": \"%s\",\n"
                    "  \"gpu_family\": \"%s\",\n"
                    "  \"macos_build\": \"%s\",\n"
                    "  \"pipelines_cached\": %u,\n"
                    "  \"archive_bytes\": %llu\n"
                    "}\n",
                    esc_key.c_str(),
                    esc_gpu.c_str(),
                    esc_fam.c_str(),
                    esc_bld.c_str(),
                    cache->stats.pipelines_cached,
                    (unsigned long long)cache->stats.archive_bytes);
            fclose(mf);
        }
        return true;
    }
}

void *dm_shader_cache_create_render_pso(dm_shader_cache_t *cache,
                                        void *mtl_render_pipeline_desc,
                                        bool strict_archive_only,
                                        char *err_buf,
                                        size_t err_cap) {
    if (!cache || !cache->device || !cache->archive || !mtl_render_pipeline_desc) {
        set_err_msg(err_buf, err_cap, "Invalid cache or render pipeline descriptor");
        return nullptr;
    }
    @autoreleasepool {
        MTLRenderPipelineDescriptor *src_rpd = (__bridge MTLRenderPipelineDescriptor *)mtl_render_pipeline_desc;
        MTLRenderPipelineDescriptor *rpd = [src_rpd copy];
        if (!rpd) {
            set_err_msg(err_buf, err_cap, "Failed to copy MTLRenderPipelineDescriptor");
            return nullptr;
        }
        rpd.binaryArchives = @[cache->archive];
        MTLPipelineOption opts = strict_archive_only ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone;
        NSError *err = nil;
        id<MTLRenderPipelineState> pso = [cache->device newRenderPipelineStateWithDescriptor:rpd
                                                                                    options:opts
                                                                                 reflection:nil
                                                                                      error:&err];
        if (!pso) {
            copy_err(err, err_buf, err_cap, "newRenderPipelineStateWithDescriptor failed");
            return nullptr;
        }
        return (__bridge_retained void *)pso;
    }
}

void *dm_shader_cache_create_compute_pso(dm_shader_cache_t *cache,
                                         void *mtl_compute_pipeline_desc,
                                         bool strict_archive_only,
                                         char *err_buf,
                                         size_t err_cap) {
    if (!cache || !cache->device || !cache->archive || !mtl_compute_pipeline_desc) {
        set_err_msg(err_buf, err_cap, "Invalid cache or compute pipeline descriptor");
        return nullptr;
    }
    @autoreleasepool {
        MTLComputePipelineDescriptor *src_cpd = (__bridge MTLComputePipelineDescriptor *)mtl_compute_pipeline_desc;
        MTLComputePipelineDescriptor *cpd = [src_cpd copy];
        if (!cpd) {
            set_err_msg(err_buf, err_cap, "Failed to copy MTLComputePipelineDescriptor");
            return nullptr;
        }
        cpd.binaryArchives = @[cache->archive];
        MTLPipelineOption opts = strict_archive_only ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone;
        NSError *err = nil;
        id<MTLComputePipelineState> pso = [cache->device newComputePipelineStateWithDescriptor:cpd
                                                                                      options:opts
                                                                                   reflection:nil
                                                                                        error:&err];
        if (!pso) {
            copy_err(err, err_buf, err_cap, "newComputePipelineStateWithDescriptor failed");
            return nullptr;
        }
        return (__bridge_retained void *)pso;
    }
}

dm_shader_cache_stats_t dm_shader_cache_stats(const dm_shader_cache_t *cache) {
    dm_shader_cache_stats_t empty{};
    return cache ? cache->stats : empty;
}
