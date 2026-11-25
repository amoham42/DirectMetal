#include "dm_shader_cache.h"
#include "dm_metal_core.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>

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
    return mkdir(path.c_str(), 0755) == 0 || errno == EEXIST;
}

static void copy_err(NSError *err, char *buf, size_t cap) {
    if (!buf || cap == 0) return;
    if (err && err.localizedDescription) {
        snprintf(buf, cap, "%s", err.localizedDescription.UTF8String);
    } else {
        buf[0] = '\0';
    }
}

dm_shader_cache_t *dm_shader_cache_open(const char *cache_root,
                                        const char *game_build_id,
                                        char *err_buf,
                                        size_t err_cap) {
    if (!cache_root || !game_build_id || !cache_root[0] || !game_build_id[0]) {
        if (err_buf && err_cap > 0) snprintf(err_buf, err_cap, "Invalid cache_root or game_build_id");
        return nullptr;
    }

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            if (err_buf && err_cap > 0) snprintf(err_buf, err_cap, "MTLCreateSystemDefaultDevice returned nil");
            return nullptr;
        }

        dm_metal_device_info_t info{};
        if (!dm_metal_query_device(&info)) {
            if (err_buf && err_cap > 0) snprintf(err_buf, err_cap, "dm_metal_query_device failed");
            return nullptr;
        }

        const int metal_major = info.supports_metal4 ? 4 : 3;
        char cache_key[192];
        snprintf(cache_key, sizeof(cache_key), "%s_%s_m%d", game_build_id, info.cache_key, metal_major);

        std::string dir = std::string(cache_root) + "/" + cache_key;
        if (!mkdir_p(dir)) {
            if (err_buf && err_cap > 0) snprintf(err_buf, err_cap, "Failed to create cache dir %s", dir.c_str());
            return nullptr;
        }

        std::string archive_path = dir + "/pipelines.metallibarchive";
        std::string manifest_path = dir + "/manifest.json";

        struct stat st{};
        const bool exists = (stat(archive_path.c_str(), &st) == 0 && st.st_size > 0);

        MTLBinaryArchiveDescriptor *bad = [MTLBinaryArchiveDescriptor new];
        if (exists) {
            bad.url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:archive_path.c_str()]];
        } else {
            bad.url = nil;
        }

        NSError *err = nil;
        id<MTLBinaryArchive> arch = [dev newBinaryArchiveWithDescriptor:bad error:&err];
        if (!arch && exists) {
            // Fall back to fresh archive if OS/GPU invalidated existing archive
            bad.url = nil;
            arch = [dev newBinaryArchiveWithDescriptor:bad error:&err];
        }
        if (!arch) {
            copy_err(err, err_buf, err_cap);
            return nullptr;
        }

        auto *cache = new dm_shader_cache();
        cache->device = dev;
        cache->archive = arch;
        memset(&cache->stats, 0, sizeof(cache->stats));
        snprintf(cache->stats.cache_key, sizeof(cache->stats.cache_key), "%s", cache_key);
        snprintf(cache->stats.archive_path, sizeof(cache->stats.archive_path), "%s", archive_path.c_str());
        snprintf(cache->stats.manifest_path, sizeof(cache->stats.manifest_path), "%s", manifest_path.c_str());
        cache->stats.loaded_existing = exists;
        cache->stats.archive_bytes = exists ? (uint64_t)st.st_size : 0;
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
    if (!cache || !mtl_render_pipeline_desc) return false;
    @autoreleasepool {
        MTLRenderPipelineDescriptor *rpd = (__bridge MTLRenderPipelineDescriptor *)mtl_render_pipeline_desc;
        NSError *err = nil;
        BOOL ok = [cache->archive addRenderPipelineFunctionsWithDescriptor:rpd error:&err];
        if (!ok) {
            copy_err(err, err_buf, err_cap);
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
    if (!cache || !mtl_compute_pipeline_desc) return false;
    @autoreleasepool {
        MTLComputePipelineDescriptor *cpd = (__bridge MTLComputePipelineDescriptor *)mtl_compute_pipeline_desc;
        NSError *err = nil;
        BOOL ok = [cache->archive addComputePipelineFunctionsWithDescriptor:cpd error:&err];
        if (!ok) {
            copy_err(err, err_buf, err_cap);
            return false;
        }
        cache->stats.pipelines_cached += 1;
        return true;
    }
}

bool dm_shader_cache_flush(dm_shader_cache_t *cache, char *err_buf, size_t err_cap) {
    if (!cache) return false;
    @autoreleasepool {
        std::string tmp_path = std::string(cache->stats.archive_path) + ".tmp";
        NSURL *tmp_url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:tmp_path.c_str()]];
        NSError *err = nil;
        if (![cache->archive serializeToURL:tmp_url error:&err]) {
            copy_err(err, err_buf, err_cap);
            return false;
        }
        if (rename(tmp_path.c_str(), cache->stats.archive_path) != 0) {
            if (err_buf && err_cap > 0) snprintf(err_buf, err_cap, "rename failed");
            return false;
        }
        struct stat st{};
        if (stat(cache->stats.archive_path, &st) == 0) {
            cache->stats.archive_bytes = (uint64_t)st.st_size;
        }

        dm_metal_device_info_t info{};
        dm_metal_query_device(&info);
        FILE *mf = fopen(cache->stats.manifest_path, "w");
        if (mf) {
            fprintf(mf,
                    "{\n"
                    "  \"cache_key\": \"%s\",\n"
                    "  \"gpu_name\": \"%s\",\n"
                    "  \"gpu_family\": \"%s\",\n"
                    "  \"macos_build\": \"%s\",\n"
                    "  \"pipelines_cached\": %u,\n"
                    "  \"archive_bytes\": %llu\n"
                    "}\n",
                    cache->stats.cache_key,
                    info.gpu_name,
                    info.gpu_family,
                    info.macos_build,
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
    if (!cache || !mtl_render_pipeline_desc) return nullptr;
    @autoreleasepool {
        MTLRenderPipelineDescriptor *rpd = (__bridge MTLRenderPipelineDescriptor *)mtl_render_pipeline_desc;
        rpd.binaryArchives = @[cache->archive];
        MTLPipelineOption opts = strict_archive_only ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone;
        NSError *err = nil;
        id<MTLRenderPipelineState> pso = [cache->device newRenderPipelineStateWithDescriptor:rpd
                                                                                    options:opts
                                                                                 reflection:nil
                                                                                      error:&err];
        if (!pso) {
            copy_err(err, err_buf, err_cap);
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
    if (!cache || !mtl_compute_pipeline_desc) return nullptr;
    @autoreleasepool {
        MTLComputePipelineDescriptor *cpd = (__bridge MTLComputePipelineDescriptor *)mtl_compute_pipeline_desc;
        cpd.binaryArchives = @[cache->archive];
        MTLPipelineOption opts = strict_archive_only ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone;
        NSError *err = nil;
        id<MTLComputePipelineState> pso = [cache->device newComputePipelineStateWithDescriptor:cpd
                                                                                      options:opts
                                                                                   reflection:nil
                                                                                        error:&err];
        if (!pso) {
            copy_err(err, err_buf, err_cap);
            return nullptr;
        }
        return (__bridge_retained void *)pso;
    }
}

dm_shader_cache_stats_t dm_shader_cache_stats(const dm_shader_cache_t *cache) {
    dm_shader_cache_stats_t empty{};
    return cache ? cache->stats : empty;
}
