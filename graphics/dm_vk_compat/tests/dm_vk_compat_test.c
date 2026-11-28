#undef NDEBUG

#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define DM_CHECK(expr)                                                                  \
    do {                                                                                \
        if (!(expr)) {                                                                  \
            fprintf(stderr, "[dm_vk_compat_test] CHECK FAILED (%s:%d): %s\n",           \
                    __FILE__, __LINE__, #expr);                                         \
            abort();                                                                    \
        }                                                                               \
    } while (0)

/* --- Exact Vulkan 1.0/1.1 & Loader Layer Interface ABI definitions --- */

typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef int32_t  VkResult;
typedef void*    VkInstance;
typedef void*    VkPhysicalDevice;
typedef void*    VkDevice;
typedef void (*PFN_vkVoidFunction)(void);

#define VK_SUCCESS 0
#define VK_INCOMPLETE 5
#define VK_ERROR_INITIALIZATION_FAILED (-3)

#define VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO 1
#define VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO 3
#define VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO 12
#define VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO 14
#define VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO 47
#define VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO 48
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 1000059000
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT 1000286000
#define VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO 1000072000
#define VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO 1000072001
#define VK_LAYER_LINK_INFO 0

#define VK_FEAT_IDX_ROBUST_BUFFER_ACCESS 0
#define VK_FEAT_IDX_GEOMETRY_SHADER 3
#define VK_FEAT_IDX_FILL_MODE_NON_SOLID 13
#define VK_FEAT_IDX_SAMPLER_ANISOTROPY 19
#define VK_FEAT_IDX_SHADER_CULL_DISTANCE 39

#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT 0x00000080u
#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_MAPPED_FOREIGN_MEMORY_BIT_EXT 0x00000100u

typedef struct VkExtensionProperties {
    char extensionName[256];
    uint32_t specVersion;
} VkExtensionProperties;

typedef struct VkBaseInStructure {
    int32_t sType;
    const struct VkBaseInStructure* pNext;
} VkBaseInStructure;

typedef struct VkBufferCreateInfo {
    int32_t sType;
    const void* pNext;
    VkFlags flags;
    uint64_t size;
    VkFlags usage;
    int32_t sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices;
} VkBufferCreateInfo;

typedef struct VkImageCreateInfo {
    int32_t sType;
    const void* pNext;
    VkFlags flags;
    int32_t imageType;
    int32_t format;
    uint32_t extent[3];
    uint32_t mipLevels;
    uint32_t arrayLayers;
    int32_t samples;
    int32_t tiling;
    VkFlags usage;
    int32_t sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices;
    int32_t initialLayout;
} VkImageCreateInfo;

typedef struct VkExternalMemoryCreateInfo {
    int32_t sType;
    const void* pNext;
    uint32_t handleTypes;
} VkExternalMemoryCreateInfo;

typedef struct VkPhysicalDeviceFeatures {
    VkBool32 features[55];
} VkPhysicalDeviceFeatures;

typedef struct VkPhysicalDeviceFeatures2 {
    int32_t sType;
    void* pNext;
    VkPhysicalDeviceFeatures features;
} VkPhysicalDeviceFeatures2;

typedef struct VkPhysicalDeviceRobustness2FeaturesEXT {
    int32_t sType;
    void* pNext;
    VkBool32 robustBufferAccess2;
    VkBool32 robustImageAccess2;
    VkBool32 nullDescriptor;
} VkPhysicalDeviceRobustness2FeaturesEXT;

typedef struct VkDeviceCreateInfo {
    int32_t sType;
    const void* pNext;
    VkFlags flags;
    uint32_t queueCreateInfoCount;
    const void* pQueueCreateInfos;
    uint32_t enabledLayerCount;
    const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char* const* ppEnabledExtensionNames;
    const VkPhysicalDeviceFeatures* pEnabledFeatures;
} VkDeviceCreateInfo;

typedef struct VkInstanceCreateInfo {
    int32_t sType;
    const void* pNext;
    VkFlags flags;
    const void* pApplicationInfo;
    uint32_t enabledLayerCount;
    const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char* const* ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char*);
typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(VkDevice, const char*);
typedef PFN_vkVoidFunction (*PFN_GetPhysicalDeviceProcAddr)(VkInstance, const char*);
typedef VkResult (*PFN_vkCreateInstance)(const VkInstanceCreateInfo*, const void*, VkInstance*);
typedef void (*PFN_vkDestroyInstance)(VkInstance, const void*);
typedef VkResult (*PFN_vkCreateDevice)(VkPhysicalDevice, const VkDeviceCreateInfo*, const void*, VkDevice*);
typedef void (*PFN_vkDestroyDevice)(VkDevice, const void*);
typedef void (*PFN_vkGetPhysicalDeviceFeatures)(VkPhysicalDevice, VkPhysicalDeviceFeatures*);
typedef void (*PFN_vkGetPhysicalDeviceFeatures2)(VkPhysicalDevice, VkPhysicalDeviceFeatures2*);
typedef VkResult (*PFN_vkEnumerateDeviceExtensionProperties)(
    VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*);
typedef VkResult (*PFN_vkCreateBuffer)(VkDevice, const VkBufferCreateInfo*, const void*, void*);
typedef VkResult (*PFN_vkCreateImage)(VkDevice, const VkImageCreateInfo*, const void*, void*);

typedef enum VkNegotiateLayerStructType {
    LAYER_NEGOTIATE_UNINTIALIZED = 0,
    LAYER_NEGOTIATE_INTERFACE_STRUCT = 1
} VkNegotiateLayerStructType;

typedef struct VkNegotiateLayerInterface {
    VkNegotiateLayerStructType sType;
    void* pNext;
    uint32_t loaderLayerInterfaceVersion;
    PFN_vkGetInstanceProcAddr pfnGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnGetDeviceProcAddr;
    PFN_GetPhysicalDeviceProcAddr pfnGetPhysicalDeviceProcAddr;
} VkNegotiateLayerInterface;

typedef VkResult (*PFN_vkNegotiateLoaderLayerInterfaceVersion)(VkNegotiateLayerInterface*);

typedef struct VkLayerInstanceLink {
    struct VkLayerInstanceLink* pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    void* pfnNextGetPhysicalDeviceProcAddr;
} VkLayerInstanceLink;

typedef struct VkLayerInstanceCreateInfo {
    int32_t sType;
    const void* pNext;
    int32_t function;
    union {
        VkLayerInstanceLink* pLayerInfo;
        void* pfnSetInstanceLoaderData;
    } u;
} VkLayerInstanceCreateInfo;

typedef struct VkLayerDeviceLink {
    struct VkLayerDeviceLink* pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnNextGetDeviceProcAddr;
} VkLayerDeviceLink;

typedef struct VkLayerDeviceCreateInfo {
    int32_t sType;
    const void* pNext;
    int32_t function;
    union {
        VkLayerDeviceLink* pLayerInfo;
        void* pfnSetDeviceLoaderData;
    } u;
} VkLayerDeviceCreateInfo;

typedef struct DmLayerApi {
    void* handle;
    PFN_vkNegotiateLoaderLayerInterfaceVersion negotiate;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkGetDeviceProcAddr gdpa;
} DmLayerApi;

/* --- Mock Vulkan Loader + MoltenVK ICD Harness --- */

typedef struct MockDispatchHandle {
    void* dispatch_table_key;
    uint64_t cookie;
} MockDispatchHandle;

static int g_inst_key_token = 0x1001;
static int g_dev1_key_token = 0x2001;
static int g_dev2_key_token = 0x2002;

static MockDispatchHandle g_mock_inst  = { &g_inst_key_token, 0xABCDEF01ULL };
static MockDispatchHandle g_mock_phys  = { &g_inst_key_token, 0xABCDEF02ULL };
static MockDispatchHandle g_mock_dev1  = { &g_dev1_key_token, 0xABCDEF11ULL };
static MockDispatchHandle g_mock_dev2  = { &g_dev2_key_token, 0xABCDEF22ULL };

typedef struct MockIcdState {
    int create_instance_calls;
    int destroy_instance_calls;
    int create_device_calls;
    int destroy_device_calls;
    int create_buffer_calls;
    int create_image_calls;
    int next_dev_slot;
    VkPhysicalDeviceFeatures last_enabled_features;
    int had_enabled_features;
    uint32_t last_ext_count;
    char last_ext_names[8][256];
    const void* last_buffer_pnext;
    const void* last_image_pnext;
} MockIcdState;

static MockIcdState g_icd;

static void reset_mock_icd(void) {
    memset(&g_icd, 0, sizeof(g_icd));
}

static void mock_passthrough_instance_fn(void) {}
static void mock_passthrough_device_fn(void) {}

static VkResult mock_vkCreateInstance(
    const VkInstanceCreateInfo* pCreateInfo,
    const void* pAllocator,
    VkInstance* pInstance)
{
    (void)pAllocator;
    DM_CHECK(pCreateInfo != NULL);
    DM_CHECK(pInstance != NULL);
    g_icd.create_instance_calls++;
    *pInstance = &g_mock_inst;
    return VK_SUCCESS;
}

static void mock_vkDestroyInstance(VkInstance instance, const void* pAllocator) {
    (void)pAllocator;
    DM_CHECK(instance == &g_mock_inst);
    g_icd.destroy_instance_calls++;
}

static void mock_vkGetPhysicalDeviceFeatures(
    VkPhysicalDevice physicalDevice,
    VkPhysicalDeviceFeatures* pFeatures)
{
    DM_CHECK(physicalDevice == &g_mock_phys);
    DM_CHECK(pFeatures != NULL);
    memset(pFeatures, 0, sizeof(*pFeatures));
    pFeatures->features[VK_FEAT_IDX_ROBUST_BUFFER_ACCESS] = 1;
    pFeatures->features[VK_FEAT_IDX_SAMPLER_ANISOTROPY] = 1;
    /* geometryShader (3), fillModeNonSolid (13), shaderCullDistance (39) left 0 */
}

static void mock_vkGetPhysicalDeviceFeatures2(
    VkPhysicalDevice physicalDevice,
    VkPhysicalDeviceFeatures2* pFeatures)
{
    DM_CHECK(physicalDevice == &g_mock_phys);
    DM_CHECK(pFeatures != NULL);
    mock_vkGetPhysicalDeviceFeatures(physicalDevice, &pFeatures->features);
}

static VkResult mock_vkEnumerateDeviceExtensionProperties(
    VkPhysicalDevice physicalDevice,
    const char* pLayerName,
    uint32_t* pPropertyCount,
    VkExtensionProperties* pProperties)
{
    (void)pLayerName;
    DM_CHECK(physicalDevice == &g_mock_phys);
    DM_CHECK(pPropertyCount != NULL);

    static const VkExtensionProperties kRawExts[3] = {
        { "VK_KHR_swapchain", 70u },
        { "VK_EXT_external_memory_host", 1u },
        { "VK_KHR_portability_subset", 1u }
    };
    const uint32_t total = 3u;
    if (!pProperties) {
        *pPropertyCount = total;
        return VK_SUCCESS;
    }
    const uint32_t to_copy = (*pPropertyCount < total) ? *pPropertyCount : total;
    memcpy(pProperties, kRawExts, sizeof(VkExtensionProperties) * to_copy);
    *pPropertyCount = to_copy;
    return (to_copy < total) ? VK_INCOMPLETE : VK_SUCCESS;
}

static VkResult mock_vkCreateDevice(
    VkPhysicalDevice physicalDevice,
    const VkDeviceCreateInfo* pCreateInfo,
    const void* pAllocator,
    VkDevice* pDevice)
{
    (void)pAllocator;
    DM_CHECK(physicalDevice == &g_mock_phys);
    DM_CHECK(pCreateInfo != NULL);
    DM_CHECK(pDevice != NULL);

    g_icd.create_device_calls++;
    if (pCreateInfo->pEnabledFeatures) {
        g_icd.had_enabled_features = 1;
        g_icd.last_enabled_features = *pCreateInfo->pEnabledFeatures;
    } else {
        g_icd.had_enabled_features = 0;
        memset(&g_icd.last_enabled_features, 0, sizeof(g_icd.last_enabled_features));
    }

    g_icd.last_ext_count = pCreateInfo->enabledExtensionCount;
    for (uint32_t i = 0; i < pCreateInfo->enabledExtensionCount && i < 8u; ++i) {
        snprintf(g_icd.last_ext_names[i], sizeof(g_icd.last_ext_names[i]),
                 "%s", pCreateInfo->ppEnabledExtensionNames[i]);
    }

    *pDevice = (g_icd.next_dev_slot++ == 0) ? (VkDevice)&g_mock_dev1 : (VkDevice)&g_mock_dev2;
    return VK_SUCCESS;
}

static void mock_vkDestroyDevice(VkDevice device, const void* pAllocator) {
    (void)pAllocator;
    DM_CHECK(device == &g_mock_dev1 || device == &g_mock_dev2);
    g_icd.destroy_device_calls++;
}

static VkResult mock_vkCreateBuffer(
    VkDevice device,
    const VkBufferCreateInfo* pCreateInfo,
    const void* pAllocator,
    void* pBuffer)
{
    (void)pAllocator;
    DM_CHECK(device == &g_mock_dev1 || device == &g_mock_dev2);
    DM_CHECK(pCreateInfo != NULL);
    g_icd.create_buffer_calls++;
    g_icd.last_buffer_pnext = pCreateInfo->pNext;
    if (pBuffer) {
        *(uint64_t*)pBuffer = 0xBEEF0001ULL;
    }
    return VK_SUCCESS;
}

static VkResult mock_vkCreateImage(
    VkDevice device,
    const VkImageCreateInfo* pCreateInfo,
    const void* pAllocator,
    void* pImage)
{
    (void)pAllocator;
    DM_CHECK(device == &g_mock_dev1 || device == &g_mock_dev2);
    DM_CHECK(pCreateInfo != NULL);
    g_icd.create_image_calls++;
    g_icd.last_image_pnext = pCreateInfo->pNext;
    if (pImage) {
        *(uint64_t*)pImage = 0xCAFE0002ULL;
    }
    return VK_SUCCESS;
}

static PFN_vkVoidFunction mock_next_gdpa(VkDevice device, const char* pName) {
    (void)device;
    if (!pName) return NULL;
    if (strcmp(pName, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)mock_vkDestroyDevice;
    if (strcmp(pName, "vkCreateBuffer") == 0) return (PFN_vkVoidFunction)mock_vkCreateBuffer;
    if (strcmp(pName, "vkCreateImage") == 0) return (PFN_vkVoidFunction)mock_vkCreateImage;
    if (strcmp(pName, "vkQueueSubmit") == 0) return mock_passthrough_device_fn;
    return NULL;
}

static PFN_vkVoidFunction mock_next_gipa(VkInstance instance, const char* pName) {
    (void)instance;
    if (!pName) return NULL;
    if (strcmp(pName, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)mock_vkCreateInstance;
    if (strcmp(pName, "vkDestroyInstance") == 0) return (PFN_vkVoidFunction)mock_vkDestroyInstance;
    if (strcmp(pName, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)mock_vkCreateDevice;
    if (strcmp(pName, "vkGetPhysicalDeviceFeatures") == 0) {
        return (PFN_vkVoidFunction)mock_vkGetPhysicalDeviceFeatures;
    }
    if (strcmp(pName, "vkGetPhysicalDeviceFeatures2") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceFeatures2KHR") == 0) {
        return (PFN_vkVoidFunction)mock_vkGetPhysicalDeviceFeatures2;
    }
    if (strcmp(pName, "vkEnumerateDeviceExtensionProperties") == 0) {
        return (PFN_vkVoidFunction)mock_vkEnumerateDeviceExtensionProperties;
    }
    if (strcmp(pName, "vkEnumeratePhysicalDevices") == 0) {
        return mock_passthrough_instance_fn;
    }
    return NULL;
}

/* --- Helpers for dlsym, executable path, and dylib path resolution --- */

static void load_fn_sym(void* lib, const char* sym_name, void* out_fn, size_t fn_size) {
    void* raw = dlsym(lib, sym_name);
    memcpy(out_fn, &raw, fn_size);
}

static bool file_exists(const char* path) {
    struct stat st;
    return path && path[0] != '\0' && stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static void resolve_self_exe(const char* argv0, char* out_buf, size_t out_cap) {
    uint32_t sz = (uint32_t)out_cap;
    if (_NSGetExecutablePath(out_buf, &sz) == 0) {
        char resolved[PATH_MAX];
        if (realpath(out_buf, resolved) != NULL) {
            snprintf(out_buf, out_cap, "%s", resolved);
            return;
        }
        return;
    }
    DM_CHECK(argv0 != NULL && argv0[0] != '\0');
    snprintf(out_buf, out_cap, "%s", argv0);
}

static void resolve_dylib_path(int argc, char** argv, const char* self_exe, char* out_buf, size_t out_cap) {
    if (argc >= 2 && strncmp(argv[1], "--", 2) != 0) {
        snprintf(out_buf, out_cap, "%s", argv[1]);
        return;
    }

    char exe_dir[PATH_MAX];
    snprintf(exe_dir, sizeof(exe_dir), "%s", self_exe);
    char* slash = strrchr(exe_dir, '/');
    if (slash) {
        *slash = '\0';
        snprintf(out_buf, out_cap, "%s/libdm_vk_compat_layer.dylib", exe_dir);
        if (file_exists(out_buf)) return;
    }

    static const char* const kFallbacks[] = {
        "./libdm_vk_compat_layer.dylib",
        "./graphics/dm_vk_compat/libdm_vk_compat_layer.dylib",
        "./build/dm_vk_compat/libdm_vk_compat_layer.dylib"
    };
    for (size_t i = 0; i < sizeof(kFallbacks) / sizeof(kFallbacks[0]); ++i) {
        if (file_exists(kFallbacks[i])) {
            snprintf(out_buf, out_cap, "%s", kFallbacks[i]);
            return;
        }
    }
    snprintf(out_buf, out_cap, "./libdm_vk_compat_layer.dylib");
}

static void open_layer(const char* dylib_path, DmLayerApi* out) {
    memset(out, 0, sizeof(*out));
    dlerror();
    out->handle = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    if (!out->handle) {
        const char* err = dlerror();
        fprintf(stderr, "[dm_vk_compat_test] dlopen('%s') failed: %s\n",
                dylib_path, err ? err : "unknown error");
    }
    DM_CHECK(out->handle != NULL);

    /* Resolve layer entrypoints (remapped dm_vkGet* in manifest v1.0.0 or standard vkGet*). */
    load_fn_sym(out->handle, "vkNegotiateLoaderLayerInterfaceVersion",
                &out->negotiate, sizeof(out->negotiate));

    load_fn_sym(out->handle, "dm_vkGetInstanceProcAddr", &out->gipa, sizeof(out->gipa));
    if (!out->gipa) {
        load_fn_sym(out->handle, "vkGetInstanceProcAddr", &out->gipa, sizeof(out->gipa));
    }
    load_fn_sym(out->handle, "dm_vkGetDeviceProcAddr", &out->gdpa, sizeof(out->gdpa));
    if (!out->gdpa) {
        load_fn_sym(out->handle, "vkGetDeviceProcAddr", &out->gdpa, sizeof(out->gdpa));
    }

    DM_CHECK(out->gipa != NULL);
    DM_CHECK(out->gdpa != NULL);

    /* Internal static functions must remain hidden under -fvisibility=hidden. */
    DM_CHECK(dlsym(out->handle, "dm_vkCreateInstance") == NULL);
    DM_CHECK(dlsym(out->handle, "dm_vkCreateDevice") == NULL);
    DM_CHECK(dlsym(out->handle, "dm_vkCreateBuffer") == NULL);
    DM_CHECK(dlsym(out->handle, "dm_vkCreateImage") == NULL);
}

static void test_negotiation_or_manifest_contract(const DmLayerApi* layer) {
    if (layer->negotiate != NULL) {
        /* 1. NULL pointer returns error safely without crashing. */
        VkResult null_rc = layer->negotiate(NULL);
        DM_CHECK(null_rc != VK_SUCCESS);

        /* 2. Valid version 2 negotiation struct populates entrypoints and returns VK_SUCCESS. */
        VkNegotiateLayerInterface neg_v2;
        memset(&neg_v2, 0, sizeof(neg_v2));
        neg_v2.sType = LAYER_NEGOTIATE_INTERFACE_STRUCT;
        neg_v2.pNext = NULL;
        neg_v2.loaderLayerInterfaceVersion = 2u;
        VkResult v2_rc = layer->negotiate(&neg_v2);
        DM_CHECK(v2_rc == VK_SUCCESS);
        DM_CHECK(neg_v2.loaderLayerInterfaceVersion >= 1u &&
                 neg_v2.loaderLayerInterfaceVersion <= 2u);
        DM_CHECK(neg_v2.pfnGetInstanceProcAddr != NULL);
        DM_CHECK(neg_v2.pfnGetDeviceProcAddr != NULL);

        /* 3. Older/zero version handling does not crash and maintains valid state. */
        VkNegotiateLayerInterface neg_v0;
        memset(&neg_v0, 0, sizeof(neg_v0));
        neg_v0.sType = LAYER_NEGOTIATE_INTERFACE_STRUCT;
        neg_v0.loaderLayerInterfaceVersion = 0u;
        VkResult v0_rc = layer->negotiate(&neg_v0);
        DM_CHECK(v0_rc != VK_SUCCESS);

        VkNegotiateLayerInterface neg_v1;
        memset(&neg_v1, 0, sizeof(neg_v1));
        neg_v1.sType = LAYER_NEGOTIATE_INTERFACE_STRUCT;
        neg_v1.loaderLayerInterfaceVersion = 1u;
        VkResult v1_rc = layer->negotiate(&neg_v1);
        if (v1_rc == VK_SUCCESS) {
            DM_CHECK(neg_v1.loaderLayerInterfaceVersion == 1u);
            DM_CHECK(neg_v1.pfnGetInstanceProcAddr != NULL);
            DM_CHECK(neg_v1.pfnGetDeviceProcAddr != NULL);
        }
        printf("[dm_vk_compat_test] vkNegotiateLoaderLayerInterfaceVersion (NULL, v2, v1/v0) OK\n");
        return;
    }

    /* Manifest v1.0.0 function-table remapping contract (dm_vkGetInstanceProcAddr / dm_vkGetDeviceProcAddr). */
    DM_CHECK(dlsym(layer->handle, "dm_vkGetInstanceProcAddr") != NULL);
    DM_CHECK(dlsym(layer->handle, "dm_vkGetDeviceProcAddr") != NULL);

    const char* manifest_rel = "graphics/dm_vk_compat/VK_LAYER_DIRECTMETAL_mvk_compat.json";
    if (file_exists(manifest_rel)) {
        FILE* fp = fopen(manifest_rel, "rb");
        DM_CHECK(fp != NULL);
        char json_buf[2048];
        size_t n = fread(json_buf, 1, sizeof(json_buf) - 1, fp);
        json_buf[n] = '\0';
        fclose(fp);
        DM_CHECK(strstr(json_buf, "\"VK_LAYER_DIRECTMETAL_mvk_compat\"") != NULL);
        DM_CHECK(strstr(json_buf, "\"dm_vkGetInstanceProcAddr\"") != NULL);
        DM_CHECK(strstr(json_buf, "\"dm_vkGetDeviceProcAddr\"") != NULL);
    }
    printf("[dm_vk_compat_test] layer manifest v1.0.0 symbol remapping & hidden visibility OK\n");
}

static void test_null_unknown_and_intercepted_proc_addrs(const DmLayerApi* layer) {
    /* NULL function name safety */
    DM_CHECK(layer->gipa(NULL, NULL) == NULL);
    DM_CHECK(layer->gdpa(NULL, NULL) == NULL);

    /* Short / malformed / unknown function names */
    DM_CHECK(layer->gipa(NULL, "") == NULL);
    DM_CHECK(layer->gipa(NULL, "v") == NULL);
    DM_CHECK(layer->gipa(NULL, "vk") == NULL);
    DM_CHECK(layer->gipa(NULL, "vkNonExistentDirectMetalFunc") == NULL);

    DM_CHECK(layer->gdpa(NULL, "") == NULL);
    DM_CHECK(layer->gdpa(NULL, "v") == NULL);
    DM_CHECK(layer->gdpa(NULL, "vk") == NULL);
    DM_CHECK(layer->gdpa(NULL, "vkNonExistentDirectMetalFunc") == NULL);

    /* Layer self-lookup */
    DM_CHECK(layer->gipa(NULL, "vkGetInstanceProcAddr") == (PFN_vkVoidFunction)layer->gipa);
    DM_CHECK(layer->gipa(NULL, "vkGetDeviceProcAddr") == (PFN_vkVoidFunction)layer->gdpa);
    DM_CHECK(layer->gdpa(NULL, "vkGetDeviceProcAddr") == (PFN_vkVoidFunction)layer->gdpa);

    /* Known intercepted Vulkan instance entrypoints */
    DM_CHECK(layer->gipa(NULL, "vkCreateInstance") != NULL);
    DM_CHECK(layer->gipa(NULL, "vkDestroyInstance") != NULL);
    DM_CHECK(layer->gipa(NULL, "vkCreateDevice") != NULL);
    DM_CHECK(layer->gipa(NULL, "vkEnumerateDeviceExtensionProperties") != NULL);
    DM_CHECK(layer->gipa(NULL, "vkGetPhysicalDeviceFeatures") != NULL);
    PFN_vkVoidFunction f2 = layer->gipa(NULL, "vkGetPhysicalDeviceFeatures2");
    PFN_vkVoidFunction f2_khr = layer->gipa(NULL, "vkGetPhysicalDeviceFeatures2KHR");
    DM_CHECK(f2 != NULL);
    DM_CHECK(f2 == f2_khr);

    /* Known intercepted Vulkan device entrypoints */
    DM_CHECK(layer->gdpa(NULL, "vkDestroyDevice") != NULL);
    DM_CHECK(layer->gdpa(NULL, "vkCreateBuffer") != NULL);
    DM_CHECK(layer->gdpa(NULL, "vkCreateImage") != NULL);

    printf("[dm_vk_compat_test] proc-addr NULL, unknown, self-lookup & intercepted hooks OK\n");
}

static void test_loader_chain_and_compat_masking(const DmLayerApi* layer) {
    reset_mock_icd();

    PFN_vkCreateInstance pfn_create_inst =
        (PFN_vkCreateInstance)layer->gipa(NULL, "vkCreateInstance");
    PFN_vkDestroyInstance pfn_destroy_inst =
        (PFN_vkDestroyInstance)layer->gipa(NULL, "vkDestroyInstance");
    PFN_vkCreateDevice pfn_create_dev =
        (PFN_vkCreateDevice)layer->gipa(NULL, "vkCreateDevice");
    PFN_vkEnumerateDeviceExtensionProperties pfn_enum_exts =
        (PFN_vkEnumerateDeviceExtensionProperties)layer->gipa(
            NULL, "vkEnumerateDeviceExtensionProperties");
    PFN_vkGetPhysicalDeviceFeatures pfn_get_feats =
        (PFN_vkGetPhysicalDeviceFeatures)layer->gipa(NULL, "vkGetPhysicalDeviceFeatures");
    PFN_vkGetPhysicalDeviceFeatures2 pfn_get_feats2 =
        (PFN_vkGetPhysicalDeviceFeatures2)layer->gipa(NULL, "vkGetPhysicalDeviceFeatures2");

    PFN_vkDestroyDevice pfn_destroy_dev =
        (PFN_vkDestroyDevice)layer->gdpa(NULL, "vkDestroyDevice");
    PFN_vkCreateBuffer pfn_create_buf =
        (PFN_vkCreateBuffer)layer->gdpa(NULL, "vkCreateBuffer");
    PFN_vkCreateImage pfn_create_img =
        (PFN_vkCreateImage)layer->gdpa(NULL, "vkCreateImage");

    DM_CHECK(pfn_create_inst && pfn_destroy_inst && pfn_create_dev);
    DM_CHECK(pfn_enum_exts && pfn_get_feats && pfn_get_feats2);
    DM_CHECK(pfn_destroy_dev && pfn_create_buf && pfn_create_img);

    /* Error guards when loader link info or pointers are missing */
    VkInstance inst = NULL;
    VkInstanceCreateInfo empty_ici;
    memset(&empty_ici, 0, sizeof(empty_ici));
    empty_ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    DM_CHECK(pfn_create_inst(NULL, NULL, &inst) == VK_ERROR_INITIALIZATION_FAILED);
    DM_CHECK(pfn_create_inst(&empty_ici, NULL, NULL) == VK_ERROR_INITIALIZATION_FAILED);
    DM_CHECK(pfn_create_inst(&empty_ici, NULL, &inst) == VK_ERROR_INITIALIZATION_FAILED);

    VkDevice dev1 = NULL;
    VkDeviceCreateInfo empty_dci;
    memset(&empty_dci, 0, sizeof(empty_dci));
    empty_dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    DM_CHECK(pfn_create_dev(&g_mock_phys, NULL, NULL, &dev1) == VK_ERROR_INITIALIZATION_FAILED);
    DM_CHECK(pfn_create_dev(&g_mock_phys, &empty_dci, NULL, NULL) == VK_ERROR_INITIALIZATION_FAILED);
    DM_CHECK(pfn_create_dev(&g_mock_phys, &empty_dci, NULL, &dev1) == VK_ERROR_INITIALIZATION_FAILED);

    /* Create instance with valid VkLayerInstanceCreateInfo link chain */
    VkLayerInstanceLink sentinel_inst_link = { NULL, NULL, NULL };
    VkLayerInstanceLink inst_link = { &sentinel_inst_link, mock_next_gipa, NULL };
    VkLayerInstanceCreateInfo layer_ici;
    memset(&layer_ici, 0, sizeof(layer_ici));
    layer_ici.sType = VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO;
    layer_ici.function = VK_LAYER_LINK_INFO;
    layer_ici.u.pLayerInfo = &inst_link;

    VkInstanceCreateInfo ici;
    memset(&ici, 0, sizeof(ici));
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pNext = &layer_ici;

    DM_CHECK(pfn_create_inst(&ici, NULL, &inst) == VK_SUCCESS);
    DM_CHECK(inst == &g_mock_inst);
    DM_CHECK(layer_ici.u.pLayerInfo == &sentinel_inst_link);
    DM_CHECK(g_icd.create_instance_calls == 1);

    /* Unintercepted instance proc chains to next_gipa */
    DM_CHECK(layer->gipa(inst, "vkEnumeratePhysicalDevices") == mock_passthrough_instance_fn);
    DM_CHECK(layer->gipa(inst, "vkNonExistentDirectMetalFunc") == NULL);

    /* EnumerateDeviceExtensionProperties: layer query + host-import extension filtering */
    uint32_t ext_count = 99u;
    DM_CHECK(pfn_enum_exts(&g_mock_phys, "VK_LAYER_DIRECTMETAL_mvk_compat", &ext_count, NULL) ==
             VK_SUCCESS);
    DM_CHECK(ext_count == 0u);

    DM_CHECK(pfn_enum_exts(&g_mock_phys, NULL, &ext_count, NULL) == VK_SUCCESS);
    DM_CHECK(ext_count == 2u); /* VK_EXT_external_memory_host filtered out */

    VkExtensionProperties ext_props[3];
    memset(ext_props, 0, sizeof(ext_props));
    uint32_t short_count = 1u;
    DM_CHECK(pfn_enum_exts(&g_mock_phys, NULL, &short_count, ext_props) == VK_INCOMPLETE);
    DM_CHECK(short_count == 1u);
    DM_CHECK(strcmp(ext_props[0].extensionName, "VK_KHR_swapchain") == 0);

    ext_count = 3u;
    DM_CHECK(pfn_enum_exts(&g_mock_phys, NULL, &ext_count, ext_props) == VK_SUCCESS);
    DM_CHECK(ext_count == 2u);
    DM_CHECK(strcmp(ext_props[0].extensionName, "VK_KHR_swapchain") == 0);
    DM_CHECK(strcmp(ext_props[1].extensionName, "VK_KHR_portability_subset") == 0);

    /* Default physical device features do NOT synthesize fillModeNonSolid unless requested */
    VkPhysicalDeviceFeatures queried_feats;
    memset(&queried_feats, 0xFF, sizeof(queried_feats));
    pfn_get_feats(&g_mock_phys, &queried_feats);
    DM_CHECK(queried_feats.features[VK_FEAT_IDX_ROBUST_BUFFER_ACCESS] == 1u);
    DM_CHECK(queried_feats.features[VK_FEAT_IDX_FILL_MODE_NON_SOLID] == 0u);

    VkPhysicalDeviceFeatures2 queried_feats2;
    memset(&queried_feats2, 0, sizeof(queried_feats2));
    queried_feats2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    pfn_get_feats2(&g_mock_phys, &queried_feats2);
    DM_CHECK(queried_feats2.features.features[VK_FEAT_IDX_SAMPLER_ANISOTROPY] == 1u);
    DM_CHECK(queried_feats2.features.features[VK_FEAT_IDX_FILL_MODE_NON_SOLID] == 0u);

    /* Create primary device: verify unsupported features, Features2, Robustness2 & blocked exts masked */
    VkPhysicalDeviceRobustness2FeaturesEXT rob2;
    memset(&rob2, 0, sizeof(rob2));
    rob2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT;
    rob2.robustBufferAccess2 = 1u;
    rob2.robustImageAccess2 = 1u;
    rob2.nullDescriptor = 1u;

    VkPhysicalDeviceFeatures2 req_feats2;
    memset(&req_feats2, 0, sizeof(req_feats2));
    req_feats2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    req_feats2.pNext = &rob2;
    req_feats2.features.features[VK_FEAT_IDX_ROBUST_BUFFER_ACCESS] = 1u;
    req_feats2.features.features[VK_FEAT_IDX_GEOMETRY_SHADER] = 1u;

    VkLayerDeviceLink sentinel_dev_link = { NULL, NULL, NULL };
    VkLayerDeviceLink dev_link1 = { &sentinel_dev_link, mock_next_gipa, mock_next_gdpa };
    VkLayerDeviceCreateInfo layer_dci1;
    memset(&layer_dci1, 0, sizeof(layer_dci1));
    layer_dci1.sType = VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO;
    layer_dci1.pNext = &req_feats2;
    layer_dci1.function = VK_LAYER_LINK_INFO;
    layer_dci1.u.pLayerInfo = &dev_link1;

    VkPhysicalDeviceFeatures req_feats;
    memset(&req_feats, 0, sizeof(req_feats));
    req_feats.features[VK_FEAT_IDX_ROBUST_BUFFER_ACCESS] = 1u;
    req_feats.features[VK_FEAT_IDX_SAMPLER_ANISOTROPY] = 1u;
    req_feats.features[VK_FEAT_IDX_GEOMETRY_SHADER] = 1u;
    req_feats.features[VK_FEAT_IDX_SHADER_CULL_DISTANCE] = 1u;

    const char* req_exts[2] = {
        "VK_KHR_swapchain",
        "VK_EXT_external_memory_host"
    };

    VkDeviceCreateInfo dci;
    memset(&dci, 0, sizeof(dci));
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.pNext = &layer_dci1;
    dci.enabledExtensionCount = 2u;
    dci.ppEnabledExtensionNames = req_exts;
    dci.pEnabledFeatures = &req_feats;

    DM_CHECK(pfn_create_dev(&g_mock_phys, &dci, NULL, &dev1) == VK_SUCCESS);
    DM_CHECK(dev1 == &g_mock_dev1);
    DM_CHECK(layer_dci1.u.pLayerInfo == &sentinel_dev_link);
    DM_CHECK(g_icd.had_enabled_features == 1);
    DM_CHECK(g_icd.last_enabled_features.features[VK_FEAT_IDX_ROBUST_BUFFER_ACCESS] == 1u);
    DM_CHECK(g_icd.last_enabled_features.features[VK_FEAT_IDX_SAMPLER_ANISOTROPY] == 1u);
    DM_CHECK(g_icd.last_enabled_features.features[VK_FEAT_IDX_GEOMETRY_SHADER] == 0u);
    DM_CHECK(g_icd.last_enabled_features.features[VK_FEAT_IDX_SHADER_CULL_DISTANCE] == 0u);
    /* Caller's original req_feats struct must not be mutated */
    DM_CHECK(req_feats.features[VK_FEAT_IDX_GEOMETRY_SHADER] == 1u);

    /* pNext Features2 and Robustness2 masked */
    DM_CHECK(req_feats2.features.features[VK_FEAT_IDX_ROBUST_BUFFER_ACCESS] == 1u);
    DM_CHECK(req_feats2.features.features[VK_FEAT_IDX_GEOMETRY_SHADER] == 0u);
    DM_CHECK(rob2.robustBufferAccess2 == 0u);
    DM_CHECK(rob2.robustImageAccess2 == 0u);
    DM_CHECK(rob2.nullDescriptor == 0u);

    /* Blocked VK_EXT_external_memory_host stripped from device extensions */
    DM_CHECK(g_icd.last_ext_count == 1u);
    DM_CHECK(strcmp(g_icd.last_ext_names[0], "VK_KHR_swapchain") == 0);

    /* Create secondary device to exercise non-primary mutex fallback dispatch */
    VkLayerDeviceLink dev_link2 = { &sentinel_dev_link, mock_next_gipa, mock_next_gdpa };
    VkLayerDeviceCreateInfo layer_dci2;
    memset(&layer_dci2, 0, sizeof(layer_dci2));
    layer_dci2.sType = VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO;
    layer_dci2.function = VK_LAYER_LINK_INFO;
    layer_dci2.u.pLayerInfo = &dev_link2;

    VkDeviceCreateInfo dci2;
    memset(&dci2, 0, sizeof(dci2));
    dci2.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci2.pNext = &layer_dci2;

    VkDevice dev2 = NULL;
    DM_CHECK(pfn_create_dev(&g_mock_phys, &dci2, NULL, &dev2) == VK_SUCCESS);
    DM_CHECK(dev2 == &g_mock_dev2);

    /* Unintercepted device proc chains via primary atomic fast path and secondary fallback */
    DM_CHECK(layer->gdpa(dev1, "vkQueueSubmit") == mock_passthrough_device_fn);
    DM_CHECK(layer->gdpa(dev2, "vkQueueSubmit") == mock_passthrough_device_fn);

    /* Buffer & Image creation strips host external memory pNext nodes */
    VkBaseInStructure benign_tail = { 999999, NULL };
    VkExternalMemoryCreateInfo ext_buf_mem = {
        VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
        &benign_tail,
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT
    };
    VkBufferCreateInfo bci;
    memset(&bci, 0, sizeof(bci));
    bci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bci.pNext = &ext_buf_mem;
    bci.size = 4096u;

    uint64_t dummy_buf = 0;
    DM_CHECK(pfn_create_buf(dev1, &bci, NULL, &dummy_buf) == VK_SUCCESS);
    DM_CHECK(dummy_buf == 0xBEEF0001ULL);
    DM_CHECK(g_icd.last_buffer_pnext == &benign_tail);

    DM_CHECK(pfn_create_buf(dev2, &bci, NULL, &dummy_buf) == VK_SUCCESS);
    DM_CHECK(g_icd.create_buffer_calls == 2);
    DM_CHECK(g_icd.last_buffer_pnext == &benign_tail);

    VkExternalMemoryCreateInfo ext_img_mem = {
        VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        NULL,
        VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_MAPPED_FOREIGN_MEMORY_BIT_EXT
    };
    VkImageCreateInfo img_ci;
    memset(&img_ci, 0, sizeof(img_ci));
    img_ci.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    img_ci.pNext = &ext_img_mem;

    uint64_t dummy_img = 0;
    DM_CHECK(pfn_create_img(dev1, &img_ci, NULL, &dummy_img) == VK_SUCCESS);
    DM_CHECK(dummy_img == 0xCAFE0002ULL);
    DM_CHECK(g_icd.last_image_pnext == NULL);

    /* Destroy devices & instance cleanly */
    pfn_destroy_dev(dev1, NULL);
    pfn_destroy_dev(dev2, NULL);
    DM_CHECK(g_icd.destroy_device_calls == 2);
    DM_CHECK(layer->gdpa(dev1, "vkQueueSubmit") == NULL);

    pfn_destroy_inst(inst, NULL);
    DM_CHECK(g_icd.destroy_instance_calls == 1);
    DM_CHECK(layer->gipa(inst, "vkEnumeratePhysicalDevices") == NULL);

    printf("[dm_vk_compat_test] loader link chain, feature/ext masking & pNext stripping OK\n");
}

/* --- Subprocess environment toggle verification --- */

static int run_subtest_disabled(const char* dylib_path) {
    DmLayerApi layer;
    open_layer(dylib_path, &layer);
    reset_mock_icd();

    /* Core loader link functions stay registered, while optional compat hooks are bypassed */
    DM_CHECK(layer.gipa(NULL, "vkCreateInstance") != NULL);
    DM_CHECK(layer.gipa(NULL, "vkCreateDevice") != NULL);
    DM_CHECK(layer.gipa(NULL, "vkDestroyInstance") != NULL);
    DM_CHECK(layer.gipa(NULL, "vkGetInstanceProcAddr") == (PFN_vkVoidFunction)layer.gipa);
    DM_CHECK(layer.gipa(NULL, "vkGetDeviceProcAddr") == (PFN_vkVoidFunction)layer.gdpa);

    DM_CHECK(layer.gipa(NULL, "vkEnumerateDeviceExtensionProperties") == NULL);
    DM_CHECK(layer.gipa(NULL, "vkGetPhysicalDeviceFeatures") == NULL);
    DM_CHECK(layer.gipa(NULL, "vkGetPhysicalDeviceFeatures2") == NULL);
    DM_CHECK(layer.gipa(NULL, "vkGetPhysicalDeviceFeatures2KHR") == NULL);

    DM_CHECK(layer.gdpa(NULL, "vkDestroyDevice") != NULL);
    DM_CHECK(layer.gdpa(NULL, "vkCreateBuffer") == NULL);
    DM_CHECK(layer.gdpa(NULL, "vkCreateImage") == NULL);

    /* Verify vkCreateDevice passes features & extensions untouched when layer is disabled */
    PFN_vkCreateInstance pfn_create_inst =
        (PFN_vkCreateInstance)layer.gipa(NULL, "vkCreateInstance");
    PFN_vkDestroyInstance pfn_destroy_inst =
        (PFN_vkDestroyInstance)layer.gipa(NULL, "vkDestroyInstance");
    PFN_vkCreateDevice pfn_create_dev =
        (PFN_vkCreateDevice)layer.gipa(NULL, "vkCreateDevice");
    PFN_vkDestroyDevice pfn_destroy_dev =
        (PFN_vkDestroyDevice)layer.gdpa(NULL, "vkDestroyDevice");

    VkLayerInstanceLink inst_link = { NULL, mock_next_gipa, NULL };
    VkLayerInstanceCreateInfo layer_ici;
    memset(&layer_ici, 0, sizeof(layer_ici));
    layer_ici.sType = VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO;
    layer_ici.function = VK_LAYER_LINK_INFO;
    layer_ici.u.pLayerInfo = &inst_link;

    VkInstanceCreateInfo ici;
    memset(&ici, 0, sizeof(ici));
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pNext = &layer_ici;

    VkInstance inst = NULL;
    DM_CHECK(pfn_create_inst(&ici, NULL, &inst) == VK_SUCCESS);

    VkLayerDeviceLink dev_link = { NULL, mock_next_gipa, mock_next_gdpa };
    VkLayerDeviceCreateInfo layer_dci;
    memset(&layer_dci, 0, sizeof(layer_dci));
    layer_dci.sType = VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO;
    layer_dci.function = VK_LAYER_LINK_INFO;
    layer_dci.u.pLayerInfo = &dev_link;

    VkPhysicalDeviceFeatures req_feats;
    memset(&req_feats, 0, sizeof(req_feats));
    req_feats.features[VK_FEAT_IDX_GEOMETRY_SHADER] = 1u;

    const char* req_exts[1] = { "VK_EXT_external_memory_host" };
    VkDeviceCreateInfo dci;
    memset(&dci, 0, sizeof(dci));
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.pNext = &layer_dci;
    dci.enabledExtensionCount = 1u;
    dci.ppEnabledExtensionNames = req_exts;
    dci.pEnabledFeatures = &req_feats;

    VkDevice dev = NULL;
    DM_CHECK(pfn_create_dev(&g_mock_phys, &dci, NULL, &dev) == VK_SUCCESS);
    DM_CHECK(g_icd.last_enabled_features.features[VK_FEAT_IDX_GEOMETRY_SHADER] == 1u);
    DM_CHECK(g_icd.last_ext_count == 1u);
    DM_CHECK(strcmp(g_icd.last_ext_names[0], "VK_EXT_external_memory_host") == 0);

    pfn_destroy_dev(dev, NULL);
    pfn_destroy_inst(inst, NULL);
    dlclose(layer.handle);
    return 0;
}

static int run_subtest_fillmode_hostimport(const char* dylib_path) {
    DmLayerApi layer;
    open_layer(dylib_path, &layer);
    reset_mock_icd();

    PFN_vkCreateInstance pfn_create_inst =
        (PFN_vkCreateInstance)layer.gipa(NULL, "vkCreateInstance");
    PFN_vkDestroyInstance pfn_destroy_inst =
        (PFN_vkDestroyInstance)layer.gipa(NULL, "vkDestroyInstance");
    PFN_vkGetPhysicalDeviceFeatures pfn_get_feats =
        (PFN_vkGetPhysicalDeviceFeatures)layer.gipa(NULL, "vkGetPhysicalDeviceFeatures");
    PFN_vkGetPhysicalDeviceFeatures2 pfn_get_feats2 =
        (PFN_vkGetPhysicalDeviceFeatures2)layer.gipa(NULL, "vkGetPhysicalDeviceFeatures2");
    PFN_vkEnumerateDeviceExtensionProperties pfn_enum_exts =
        (PFN_vkEnumerateDeviceExtensionProperties)layer.gipa(
            NULL, "vkEnumerateDeviceExtensionProperties");

    VkLayerInstanceLink inst_link = { NULL, mock_next_gipa, NULL };
    VkLayerInstanceCreateInfo layer_ici;
    memset(&layer_ici, 0, sizeof(layer_ici));
    layer_ici.sType = VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO;
    layer_ici.function = VK_LAYER_LINK_INFO;
    layer_ici.u.pLayerInfo = &inst_link;

    VkInstanceCreateInfo ici;
    memset(&ici, 0, sizeof(ici));
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pNext = &layer_ici;

    VkInstance inst = NULL;
    DM_CHECK(pfn_create_inst(&ici, NULL, &inst) == VK_SUCCESS);

    /* DM_VK_COMPAT_ADVERTISE_FILLMODE=1 advertises fillModeNonSolid (index 13) */
    VkPhysicalDeviceFeatures feats;
    memset(&feats, 0, sizeof(feats));
    pfn_get_feats(&g_mock_phys, &feats);
    DM_CHECK(feats.features[VK_FEAT_IDX_FILL_MODE_NON_SOLID] == 1u);

    VkPhysicalDeviceFeatures2 feats2;
    memset(&feats2, 0, sizeof(feats2));
    feats2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    pfn_get_feats2(&g_mock_phys, &feats2);
    DM_CHECK(feats2.features.features[VK_FEAT_IDX_FILL_MODE_NON_SOLID] == 1u);

    /* DM_VK_COMPAT_HOST_IMPORT=1 preserves VK_EXT_external_memory_host */
    uint32_t ext_count = 0u;
    DM_CHECK(pfn_enum_exts(&g_mock_phys, NULL, &ext_count, NULL) == VK_SUCCESS);
    DM_CHECK(ext_count == 3u);

    pfn_destroy_inst(inst, NULL);
    dlclose(layer.handle);
    return 0;
}

static void spawn_env_subtest(
    const char* self_exe,
    const char* mode_flag,
    const char* dylib_path,
    const char* enable_val,
    const char* disable_val,
    const char* fillmode_val,
    const char* hostimport_val)
{
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    DM_CHECK(pid >= 0);

    if (pid == 0) {
        if (enable_val) setenv("DM_VK_COMPAT_ENABLE", enable_val, 1);
        else unsetenv("DM_VK_COMPAT_ENABLE");

        if (disable_val) setenv("DM_VK_COMPAT_DISABLE", disable_val, 1);
        else unsetenv("DM_VK_COMPAT_DISABLE");

        if (fillmode_val) setenv("DM_VK_COMPAT_ADVERTISE_FILLMODE", fillmode_val, 1);
        else unsetenv("DM_VK_COMPAT_ADVERTISE_FILLMODE");

        if (hostimport_val) setenv("DM_VK_COMPAT_HOST_IMPORT", hostimport_val, 1);
        else unsetenv("DM_VK_COMPAT_HOST_IMPORT");

        char* const child_argv[] = {
            (char*)self_exe,
            (char*)mode_flag,
            (char*)dylib_path,
            NULL
        };
        execv(self_exe, child_argv);
        perror("[dm_vk_compat_test] execv failed");
        _exit(127);
    }

    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited == -1 && errno == EINTR);

    DM_CHECK(waited == pid);
    DM_CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

int main(int argc, char** argv) {
    if (argc == 3 && strcmp(argv[1], "--subtest-disabled") == 0) {
        return run_subtest_disabled(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "--subtest-fillmode-hostimport") == 0) {
        return run_subtest_fillmode_hostimport(argv[2]);
    }

    /* Normalize environment before dlopen() so default-mode assertions are deterministic. */
    unsetenv("DM_VK_COMPAT_ENABLE");
    unsetenv("DM_VK_COMPAT_DISABLE");
    unsetenv("DM_VK_COMPAT_HOST_IMPORT");
    unsetenv("DM_VK_COMPAT_ADVERTISE_FILLMODE");
    unsetenv("DM_VK_COMPAT_VERBOSE");
    unsetenv("DM_VK_COMPAT_DEBUG");

    char self_exe[PATH_MAX];
    char dylib_path[PATH_MAX];
    resolve_self_exe(argv[0], self_exe, sizeof(self_exe));
    resolve_dylib_path(argc, argv, self_exe, dylib_path, sizeof(dylib_path));

    DmLayerApi layer;
    open_layer(dylib_path, &layer);

    test_negotiation_or_manifest_contract(&layer);
    test_null_unknown_and_intercepted_proc_addrs(&layer);
    test_loader_chain_and_compat_masking(&layer);

    dlclose(layer.handle);

    /* Verify DM_VK_COMPAT_ENABLE=0, DM_VK_COMPAT_DISABLE=1, and fillmode/host_import toggles */
    spawn_env_subtest(self_exe, "--subtest-disabled", dylib_path, "0", NULL, NULL, NULL);
    spawn_env_subtest(self_exe, "--subtest-disabled", dylib_path, "1", "1", NULL, NULL);
    spawn_env_subtest(self_exe, "--subtest-fillmode-hostimport", dylib_path, "1", "0", "1", "1");
    printf("[dm_vk_compat_test] subprocess environment toggles (ENABLE=0, DISABLE=1, FILLMODE/HOST_IMPORT) OK\n");

    printf("[dm_vk_compat_test] ALL CHECKS PASSED\n");
    return 0;
}
