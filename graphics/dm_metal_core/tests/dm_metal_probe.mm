#include "dm_metal_core.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_metal_probe] CHECK FAILED (%s:%d): %s\n",             \
                    __FILE__, __LINE__, #expr);                                        \
            std::abort();                                                              \
        }                                                                              \
    } while (0)

static bool ctest_skip_allowed(void) {
    const char *v = std::getenv("DM_CTEST_ALLOW_SKIP");
    return v && v[0] && std::strcmp(v, "0") != 0;
}

template <size_t N>
static void verify_bounded_nonempty_cstr(const char (&buf)[N], bool forbid_separators) {
    const void *nul = std::memchr(buf, '\0', N);
    DM_CHECK(nul != nullptr);
    const size_t len = std::strlen(buf);
    DM_CHECK(len > 0 && len < N);
    if (forbid_separators) {
        for (size_t i = 0; i < len; ++i) {
            const unsigned char ch = static_cast<unsigned char>(buf[i]);
            DM_CHECK(ch > 0x20u && ch != '/' && ch != '\\');
        }
    }
}

static bool is_known_gpu_family(const char *family) {
    return std::strcmp(family, "Apple10") == 0 ||
           std::strcmp(family, "Apple9") == 0 ||
           std::strcmp(family, "Apple8") == 0 ||
           std::strcmp(family, "Apple7") == 0 ||
           std::strcmp(family, "Mac2") == 0;
}

static void verify_semver_triplet(const char *ver) {
    DM_CHECK(ver != nullptr && std::isdigit(static_cast<unsigned char>(ver[0])));
    char *end = nullptr;
    const long major = std::strtol(ver, &end, 10);
    DM_CHECK(major >= 11 && end != nullptr && *end == '.');
    const char *minor_start = end + 1;
    DM_CHECK(std::isdigit(static_cast<unsigned char>(minor_start[0])));
    const long minor = std::strtol(minor_start, &end, 10);
    DM_CHECK(minor >= 0 && end != nullptr && *end == '.');
    const char *patch_start = end + 1;
    DM_CHECK(std::isdigit(static_cast<unsigned char>(patch_start[0])));
    const long patch = std::strtol(patch_start, &end, 10);
    DM_CHECK(patch >= 0 && end != nullptr && *end == '\0');
}

static void verify_cache_key_formatting(const dm_metal_device_info_t &info) {
    verify_bounded_nonempty_cstr(info.cache_key, true);

    const char *sep = std::strchr(info.cache_key, '_');
    DM_CHECK(sep != nullptr && sep > info.cache_key);
    DM_CHECK(std::strcmp(sep + 1, info.macos_build) == 0);

    // Prefix before '_' must be strictly lowercase alphanumeric matching gpu_family
    for (const char *p = info.cache_key; p < sep; ++p) {
        const unsigned char ch = static_cast<unsigned char>(*p);
        DM_CHECK(std::islower(ch) || std::isdigit(ch));
    }

    char expected_family_lower[sizeof(info.gpu_family)] = {};
    for (size_t i = 0; i < sizeof(info.gpu_family) - 1 && info.gpu_family[i] != '\0'; ++i) {
        const unsigned char ch = static_cast<unsigned char>(info.gpu_family[i]);
        expected_family_lower[i] = static_cast<char>(std::tolower(ch));
    }

    char expected_key[sizeof(info.cache_key)] = {};
    const int n = snprintf(expected_key, sizeof(expected_key), "%s_%s",
                           expected_family_lower, info.macos_build);
    DM_CHECK(n > 0 && static_cast<size_t>(n) < sizeof(expected_key));
    DM_CHECK(std::strcmp(info.cache_key, expected_key) == 0);
}

static void verify_device_info_invariants(const dm_metal_device_info_t &info) {
    verify_bounded_nonempty_cstr(info.gpu_name, false);
    verify_bounded_nonempty_cstr(info.gpu_family, true);
    verify_bounded_nonempty_cstr(info.macos_version, true);
    verify_bounded_nonempty_cstr(info.macos_build, true);
    DM_CHECK(is_known_gpu_family(info.gpu_family));
    verify_semver_triplet(info.macos_version);
    verify_cache_key_formatting(info);

    // Ensure boolean fields are sanitized (0 or 1) even when input struct was poisoned
    DM_CHECK(*reinterpret_cast<const unsigned char *>(&info.has_unified_memory) <= 1u);
    DM_CHECK(*reinterpret_cast<const unsigned char *>(&info.supports_metal3) <= 1u);
    DM_CHECK(*reinterpret_cast<const unsigned char *>(&info.supports_metal4) <= 1u);
    DM_CHECK(*reinterpret_cast<const unsigned char *>(&info.supports_raytracing) <= 1u);
    DM_CHECK(*reinterpret_cast<const unsigned char *>(&info.supports_barycentrics) <= 1u);

    // Non-zero capability invariants when a Metal GPU is present
    DM_CHECK(info.max_buffer_length > 0);
    DM_CHECK(info.registry_id != 0);
}

static void run_device_independent_null_tests(void) {
    // NULL pointer safety on capability query
    DM_CHECK(!dm_metal_query_device(nullptr));

    // Zero-capacity error buffer must never be modified regardless of GPU availability
    char untouched[3] = {'K', 'V', '\0'};
    (void)dm_metal_run_smoke_test(untouched, 0);
    DM_CHECK(untouched[0] == 'K' && untouched[1] == 'V' && untouched[2] == '\0');
}

int main(void) {
    run_device_independent_null_tests();

    // Poison struct before querying to prove complete sanitization of strings and booleans
    dm_metal_device_info_t info;
    std::memset(&info, 0xA5, sizeof(info));
    if (!dm_metal_query_device(&info)) {
        // Failed query must leave poisoned struct cleanly zeroed
        DM_CHECK(info.gpu_name[0] == '\0');
        DM_CHECK(info.gpu_family[0] == '\0');
        DM_CHECK(info.cache_key[0] == '\0');
        DM_CHECK(info.max_buffer_length == 0);
        DM_CHECK(info.recommended_working_set_bytes == 0);

        // NULL / tiny error buffer safety on headless failure path
        DM_CHECK(!dm_metal_run_smoke_test(nullptr, 0));
        DM_CHECK(!dm_metal_run_smoke_test(nullptr, 64));
        char tiny_err[5] = {'1', '2', '3', '4', 'Z'};
        DM_CHECK(!dm_metal_run_smoke_test(tiny_err, 4));
        DM_CHECK(std::strlen(tiny_err) == 3 && tiny_err[4] == 'Z');

        if (ctest_skip_allowed()) {
            printf("[dm_metal_probe] SKIP: no Metal device available in headless environment\n");
            return 77;
        }
        fprintf(stderr, "[dm_metal_probe] FAIL: dm_metal_query_device returned false\n");
        return 1;
    }

    verify_device_info_invariants(info);

    // Repeated query must produce identical device metadata and deterministic cache_key
    dm_metal_device_info_t info_repeat;
    std::memset(&info_repeat, 0x5A, sizeof(info_repeat));
    DM_CHECK(dm_metal_query_device(&info_repeat));
    verify_device_info_invariants(info_repeat);
    DM_CHECK(std::strcmp(info.gpu_name, info_repeat.gpu_name) == 0);
    DM_CHECK(std::strcmp(info.gpu_family, info_repeat.gpu_family) == 0);
    DM_CHECK(std::strcmp(info.macos_version, info_repeat.macos_version) == 0);
    DM_CHECK(std::strcmp(info.macos_build, info_repeat.macos_build) == 0);
    DM_CHECK(std::strcmp(info.cache_key, info_repeat.cache_key) == 0);
    DM_CHECK(info.registry_id == info_repeat.registry_id);
    DM_CHECK(info.max_buffer_length == info_repeat.max_buffer_length);
    DM_CHECK(info.recommended_working_set_bytes == info_repeat.recommended_working_set_bytes);
    DM_CHECK(info.has_unified_memory == info_repeat.has_unified_memory);
    DM_CHECK(info.supports_metal3 == info_repeat.supports_metal3);
    DM_CHECK(info.supports_metal4 == info_repeat.supports_metal4);
    DM_CHECK(info.supports_raytracing == info_repeat.supports_raytracing);
    DM_CHECK(info.supports_barycentrics == info_repeat.supports_barycentrics);

    printf("[dm_metal_probe] GPU: %s\n", info.gpu_name);
    printf("[dm_metal_probe] Family: %s | Metal3: %s | Metal4: %s\n",
           info.gpu_family,
           info.supports_metal3 ? "yes" : "no",
           info.supports_metal4 ? "yes" : "no");
    printf("[dm_metal_probe] Unified Memory: %s | Max Working Set: %.2f GiB\n",
           info.has_unified_memory ? "yes" : "no",
           (double)info.recommended_working_set_bytes / (1024.0 * 1024.0 * 1024.0));
    printf("[dm_metal_probe] macOS: %s (%s) | Cache Key: %s\n",
           info.macos_version, info.macos_build, info.cache_key);
    printf("[dm_metal_probe] Raytracing: %s | Barycentrics: %s\n",
           info.supports_raytracing ? "yes" : "no",
           info.supports_barycentrics ? "yes" : "no");

    if ((!info.has_unified_memory || !info.supports_metal3) && ctest_skip_allowed()) {
        printf("[dm_metal_probe] SKIP: paravirtualized GPU lacks Apple Silicon UMA/Metal3\n");
        return 77;
    }

    DM_CHECK(info.has_unified_memory);
    DM_CHECK(info.supports_metal3);
    DM_CHECK(info.recommended_working_set_bytes > 0);
    DM_CHECK(info.max_buffer_length >= 256ULL * 1024ULL * 1024ULL);
    DM_CHECK(std::strncmp(info.gpu_family, "Apple", 5) == 0);
    if (info.supports_metal4) {
        DM_CHECK(info.supports_metal3);
    }

    // Smoke test error buffer contract: pre-dirtied buffer cleared on success, NULL/1-byte safe
    char err[256] = "stale_error_message";
    if (!dm_metal_run_smoke_test(err, sizeof(err))) {
        fprintf(stderr, "Metal smoke test failed: %s\n", err);
        std::abort();
    }
    DM_CHECK(err[0] == '\0');
    DM_CHECK(dm_metal_run_smoke_test(nullptr, 0));
    DM_CHECK(dm_metal_run_smoke_test(nullptr, 128));

    char tiny[2] = {'X', 'Z'};
    DM_CHECK(dm_metal_run_smoke_test(tiny, 1));
    DM_CHECK(tiny[0] == '\0' && tiny[1] == 'Z');

    printf("[dm_metal_probe] Unit checks (NULL guards, device strings/fields, cache_key invariants) OK\n");
    printf("[dm_metal_probe] Native Metal UMA compute + render smoke test PASSED\n");
    return 0;
}
