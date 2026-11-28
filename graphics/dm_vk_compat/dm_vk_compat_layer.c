/*
 * DirectMetal Vulkan Compatibility Layer (VK_LAYER_DIRECTMETAL_mvk_compat)
 *
 * Bridges DXVK D3D9/D3D10/D3D11 on macOS MoltenVK 1.4 by masking requested
 * device features in vkCreateDevice() against what the underlying physical
 * device actually supports (e.g., geometryShader, shaderCullDistance,
 * robustness2 flags that older DXVK-macOS requests unconditionally).
 *
 * Zero external Vulkan SDK headers required (uses exact Vulkan 1.0/1.1 ABI structs).
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include <pthread.h>

typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef int32_t  VkResult;
typedef void*    VkInstance;
typedef void*    VkPhysicalDevice;
typedef void*    VkDevice;
typedef void (*PFN_vkVoidFunction)(void);

#define VK_SUCCESS 0
#define VK_ERROR_INITIALIZATION_FAILED (-3)
#define VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO 3
#define VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO 47
#define VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO 48
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 1000059000
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT 1000286000
#define VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO 1000072000
#define VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO 1000072001
#define VK_LAYER_LINK_INFO 0

typedef struct VkExtensionProperties {
    char extensionName[256];
    uint32_t specVersion;
} VkExtensionProperties;

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

typedef struct VkBaseInStructure {
    int32_t sType;
    const struct VkBaseInStructure* pNext;
} VkBaseInStructure;

typedef struct VkBaseOutStructure {
    int32_t sType;
    struct VkBaseOutStructure* pNext;
} VkBaseOutStructure;

typedef struct VkPhysicalDeviceFeatures {
    VkBool32 features[55]; /* Exact Vulkan 1.0 VkPhysicalDeviceFeatures layout: 55 VkBool32s */
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
typedef VkResult (*PFN_vkCreateInstance)(const VkInstanceCreateInfo*, const void*, VkInstance*);
typedef void (*PFN_vkDestroyInstance)(VkInstance, const void*);
typedef VkResult (*PFN_vkCreateDevice)(VkPhysicalDevice, const VkDeviceCreateInfo*, const void*, VkDevice*);
typedef void (*PFN_vkDestroyDevice)(VkDevice, const void*);
typedef void (*PFN_vkGetPhysicalDeviceFeatures)(VkPhysicalDevice, VkPhysicalDeviceFeatures*);
typedef void (*PFN_vkGetPhysicalDeviceFeatures2)(VkPhysicalDevice, VkPhysicalDeviceFeatures2*);
typedef VkResult (*PFN_vkEnumerateDeviceExtensionProperties)(VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*);
typedef struct VkExternalMemoryBufferCreateInfo {
    int32_t sType;
    const void* pNext;
    uint32_t handleTypes;
} VkExternalMemoryBufferCreateInfo;

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

#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT 0x00000080u
#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_MAPPED_FOREIGN_MEMORY_BIT_EXT 0x00000100u
#define VK_HOST_EXTERNAL_HANDLE_MASK (VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT | VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_MAPPED_FOREIGN_MEMORY_BIT_EXT)

typedef VkResult (*PFN_vkCreateBuffer)(VkDevice, const VkBufferCreateInfo*, const void*, void*);
typedef VkResult (*PFN_vkCreateImage)(VkDevice, const VkImageCreateInfo*, const void*, void*);

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

typedef struct {
    void* key;
    PFN_vkGetInstanceProcAddr next_gipa;
    PFN_vkDestroyInstance next_destroy_instance;
    PFN_vkCreateDevice next_create_device;
    PFN_vkGetPhysicalDeviceFeatures next_get_features;
    PFN_vkGetPhysicalDeviceFeatures2 next_get_features2;
    PFN_vkEnumerateDeviceExtensionProperties next_enum_dev_exts;
} InstEntry;

typedef struct {
    void* key;
    PFN_vkGetDeviceProcAddr next_gdpa;
    PFN_vkDestroyDevice next_destroy_device;
    PFN_vkCreateBuffer next_create_buffer;
    PFN_vkCreateImage next_create_image;
} DevEntry;

typedef struct {
    int enabled;            /* DM_VK_COMPAT_ENABLE (default 1 unless "0" or DM_VK_COMPAT_DISABLE="1") */
    int host_import;        /* DM_VK_COMPAT_HOST_IMPORT == "1" */
    int advertise_fillmode; /* DM_VK_COMPAT_ADVERTISE_FILLMODE == "1" */
    int verbose;            /* DM_VK_COMPAT_VERBOSE or DM_VK_COMPAT_DEBUG enabled */
} DmVkCompatConfig;

static DmVkCompatConfig g_cfg = { 1, 0, 0, 0 };
static pthread_once_t g_cfg_once = PTHREAD_ONCE_INIT;

static int parse_env_bool(const char* name, int default_val) {
    const char* v = getenv(name);
    if (!v || v[0] == '\0') return default_val;
    if (v[0] == '0' || v[0] == 'n' || v[0] == 'N' || v[0] == 'f' || v[0] == 'F') {
        return 0;
    }
    return 1;
}

static void init_env_config_once(void) {
    const int en = parse_env_bool("DM_VK_COMPAT_ENABLE", 1);
    const int dis = parse_env_bool("DM_VK_COMPAT_DISABLE", 0);
    g_cfg.enabled = (en && !dis) ? 1 : 0;
    g_cfg.host_import = parse_env_bool("DM_VK_COMPAT_HOST_IMPORT", 0);
    g_cfg.advertise_fillmode = parse_env_bool("DM_VK_COMPAT_ADVERTISE_FILLMODE", 0);
    g_cfg.verbose = parse_env_bool("DM_VK_COMPAT_VERBOSE", 0) ||
                    parse_env_bool("DM_VK_COMPAT_DEBUG", 0);
}

static inline void ensure_env_config(void) {
    pthread_once(&g_cfg_once, init_env_config_once);
}

__attribute__((constructor))
static void dm_vk_compat_ctor(void) {
    ensure_env_config();
}

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static InstEntry g_insts[32];
static int g_inst_count = 0;
static DevEntry g_devs[64];
static int g_dev_count = 0;

/* Lock-free fast-path dispatch slot for the primary VkDevice */
static _Atomic(void*) g_primary_dev_key = NULL;
static _Atomic(PFN_vkGetDeviceProcAddr) g_primary_gdpa = NULL;
static _Atomic(PFN_vkCreateBuffer) g_primary_create_buffer = NULL;
static _Atomic(PFN_vkCreateImage) g_primary_create_image = NULL;

static inline void* dispatch_key(void* obj) {
    return obj ? *(void**)obj : NULL;
}

static void sync_primary_dev_locked(void) {
    if (g_dev_count > 0) {
        atomic_store_explicit(&g_primary_gdpa, g_devs[0].next_gdpa, memory_order_relaxed);
        atomic_store_explicit(&g_primary_create_buffer, g_devs[0].next_create_buffer, memory_order_relaxed);
        atomic_store_explicit(&g_primary_create_image, g_devs[0].next_create_image, memory_order_relaxed);
        atomic_store_explicit(&g_primary_dev_key, g_devs[0].key, memory_order_release);
    } else {
        atomic_store_explicit(&g_primary_dev_key, NULL, memory_order_release);
        atomic_store_explicit(&g_primary_gdpa, NULL, memory_order_relaxed);
        atomic_store_explicit(&g_primary_create_buffer, NULL, memory_order_relaxed);
        atomic_store_explicit(&g_primary_create_image, NULL, memory_order_relaxed);
    }
}

static InstEntry* find_inst(void* obj) {
    void* k = dispatch_key(obj);
    for (int i = 0; i < g_inst_count; ++i) {
        if (g_insts[i].key == k) return &g_insts[i];
    }
    return g_inst_count > 0 ? &g_insts[0] : NULL;
}

static DevEntry* find_dev(void* obj) {
    void* k = dispatch_key(obj);
    for (int i = 0; i < g_dev_count; ++i) {
        if (g_devs[i].key == k) return &g_devs[i];
    }
    return g_dev_count > 0 ? &g_devs[0] : NULL;
}

static VkResult dm_vkCreateInstance(
    const VkInstanceCreateInfo* pCreateInfo,
    const void* pAllocator,
    VkInstance* pInstance)
{
    ensure_env_config();
    if (!pCreateInfo || !pInstance) return VK_ERROR_INITIALIZATION_FAILED;

    VkLayerInstanceCreateInfo* chain = (VkLayerInstanceCreateInfo*)pCreateInfo->pNext;
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
                      chain->function == VK_LAYER_LINK_INFO)) {
        chain = (VkLayerInstanceCreateInfo*)chain->pNext;
    }
    if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next_gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

    PFN_vkCreateInstance next_create = (PFN_vkCreateInstance)next_gipa(NULL, "vkCreateInstance");
    if (!next_create) return VK_ERROR_INITIALIZATION_FAILED;

    VkResult res = next_create(pCreateInfo, pAllocator, pInstance);
    if (res != VK_SUCCESS) return res;

    pthread_mutex_lock(&g_lock);
    if (g_inst_count < 32) {
        InstEntry* e = &g_insts[g_inst_count++];
        e->key = dispatch_key(*pInstance);
        e->next_gipa = next_gipa;
        e->next_destroy_instance = (PFN_vkDestroyInstance)next_gipa(*pInstance, "vkDestroyInstance");
        e->next_create_device = (PFN_vkCreateDevice)next_gipa(*pInstance, "vkCreateDevice");
        e->next_get_features = (PFN_vkGetPhysicalDeviceFeatures)next_gipa(*pInstance, "vkGetPhysicalDeviceFeatures");
        e->next_get_features2 = (PFN_vkGetPhysicalDeviceFeatures2)next_gipa(*pInstance, "vkGetPhysicalDeviceFeatures2");
        if (!e->next_get_features2) {
            e->next_get_features2 = (PFN_vkGetPhysicalDeviceFeatures2)next_gipa(*pInstance, "vkGetPhysicalDeviceFeatures2KHR");
        }
        e->next_enum_dev_exts = (PFN_vkEnumerateDeviceExtensionProperties)next_gipa(*pInstance, "vkEnumerateDeviceExtensionProperties");
    }
    pthread_mutex_unlock(&g_lock);
    return res;
}

/* VkPhysicalDeviceFeatures index 13 is fillModeNonSolid (0=robustBufferAccess .. 12=depthBiasClamp, 13=fillModeNonSolid) */
#define VK_FEAT_IDX_FILL_MODE_NON_SOLID 13

static void dm_vkGetPhysicalDeviceFeatures(VkPhysicalDevice physicalDevice, VkPhysicalDeviceFeatures* pFeatures) {
    PFN_vkGetPhysicalDeviceFeatures next_fn = NULL;
    pthread_mutex_lock(&g_lock);
    InstEntry* ie = find_inst(physicalDevice);
    if (ie) next_fn = ie->next_get_features;
    pthread_mutex_unlock(&g_lock);
    if (!next_fn || !pFeatures) return;
    next_fn(physicalDevice, pFeatures);
    if (g_cfg.enabled && g_cfg.advertise_fillmode) {
        pFeatures->features[VK_FEAT_IDX_FILL_MODE_NON_SOLID] = 1;
    }
}

static void dm_vkGetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice, VkPhysicalDeviceFeatures2* pFeatures) {
    PFN_vkGetPhysicalDeviceFeatures2 next_fn = NULL;
    pthread_mutex_lock(&g_lock);
    InstEntry* ie = find_inst(physicalDevice);
    if (ie) next_fn = ie->next_get_features2;
    pthread_mutex_unlock(&g_lock);
    if (!next_fn || !pFeatures) return;
    next_fn(physicalDevice, pFeatures);
    if (g_cfg.enabled && g_cfg.advertise_fillmode) {
        pFeatures->features.features[VK_FEAT_IDX_FILL_MODE_NON_SOLID] = 1;
    }
}

static inline int is_blocked_ext(const char* name) {
    if (!name || !g_cfg.enabled || g_cfg.host_import) return 0;
    return strcmp(name, "VK_EXT_external_memory_host") == 0;
}

static VkResult dm_vkEnumerateDeviceExtensionProperties(
    VkPhysicalDevice physicalDevice,
    const char* pLayerName,
    uint32_t* pPropertyCount,
    VkExtensionProperties* pProperties)
{
    if (pLayerName && strcmp(pLayerName, "VK_LAYER_DIRECTMETAL_mvk_compat") == 0) {
        if (pPropertyCount) *pPropertyCount = 0;
        return VK_SUCCESS;
    }
    PFN_vkEnumerateDeviceExtensionProperties next_fn = NULL;
    pthread_mutex_lock(&g_lock);
    InstEntry* ie = find_inst(physicalDevice);
    if (ie) next_fn = ie->next_enum_dev_exts;
    pthread_mutex_unlock(&g_lock);
    if (!next_fn || !pPropertyCount) return VK_ERROR_INITIALIZATION_FAILED;

    if (!g_cfg.enabled || g_cfg.host_import) {
        return next_fn(physicalDevice, pLayerName, pPropertyCount, pProperties);
    }

    uint32_t raw_count = 0;
    VkResult r = next_fn(physicalDevice, pLayerName, &raw_count, NULL);
    if (r != VK_SUCCESS) return r;
    VkExtensionProperties* tmp = (VkExtensionProperties*)malloc(sizeof(VkExtensionProperties) * (raw_count ? raw_count : 1));
    if (!tmp) return VK_ERROR_INITIALIZATION_FAILED;
    r = next_fn(physicalDevice, pLayerName, &raw_count, tmp);
    if (r != VK_SUCCESS) { free(tmp); return r; }

    uint32_t kept = 0;
    for (uint32_t i = 0; i < raw_count; ++i) {
        if (!is_blocked_ext(tmp[i].extensionName)) {
            if (kept != i) tmp[kept] = tmp[i];
            kept++;
        }
    }
    if (!pProperties) {
        *pPropertyCount = kept;
        free(tmp);
        return VK_SUCCESS;
    }
    uint32_t to_copy = *pPropertyCount < kept ? *pPropertyCount : kept;
    memcpy(pProperties, tmp, sizeof(VkExtensionProperties) * to_copy);
    *pPropertyCount = to_copy;
    free(tmp);
    return (to_copy < kept) ? 5 /* VK_INCOMPLETE */ : VK_SUCCESS;
}

static void dm_vkDestroyInstance(VkInstance instance, const void* pAllocator) {
    PFN_vkDestroyInstance next_fn = NULL;
    pthread_mutex_lock(&g_lock);
    void* k = dispatch_key(instance);
    for (int i = 0; i < g_inst_count; ++i) {
        if (g_insts[i].key == k) {
            next_fn = g_insts[i].next_destroy_instance;
            g_insts[i] = g_insts[--g_inst_count];
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    if (next_fn) next_fn(instance, pAllocator);
}

static VkResult dm_vkCreateDevice(
    VkPhysicalDevice physicalDevice,
    const VkDeviceCreateInfo* pCreateInfo,
    const void* pAllocator,
    VkDevice* pDevice)
{
    ensure_env_config();
    if (!pCreateInfo || !pDevice) return VK_ERROR_INITIALIZATION_FAILED;

    VkLayerDeviceCreateInfo* chain = (VkLayerDeviceCreateInfo*)pCreateInfo->pNext;
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                      chain->function == VK_LAYER_LINK_INFO)) {
        chain = (VkLayerDeviceCreateInfo*)chain->pNext;
    }
    if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr next_gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr next_gdpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;

    PFN_vkCreateDevice next_create = (PFN_vkCreateDevice)next_gipa(NULL, "vkCreateDevice");
    PFN_vkGetPhysicalDeviceFeatures next_get_feats = NULL;
    pthread_mutex_lock(&g_lock);
    InstEntry* ie = find_inst(physicalDevice);
    if (ie) {
        if (!next_create) next_create = ie->next_create_device;
        next_get_feats = ie->next_get_features;
    }
    pthread_mutex_unlock(&g_lock);
    if (!next_create) return VK_ERROR_INITIALIZATION_FAILED;

    VkDeviceCreateInfo patched = *pCreateInfo;
    VkPhysicalDeviceFeatures supported;
    VkPhysicalDeviceFeatures masked;
    const char* filtered_exts[256];

    if (g_cfg.enabled) {
        int has_supported = 0;
        if (next_get_feats) {
            memset(&supported, 0, sizeof(supported));
            next_get_feats(physicalDevice, &supported);
            has_supported = 1;
        }

        int masked_count = 0;
        if (has_supported && patched.pEnabledFeatures) {
            masked = *patched.pEnabledFeatures;
            for (int i = 0; i < 55; ++i) {
                if (masked.features[i] && !supported.features[i]) {
                    masked.features[i] = 0;
                    masked_count++;
                }
            }
            patched.pEnabledFeatures = &masked;
        }

        /* Also mask VkPhysicalDeviceFeatures2 and Robustness2 in pNext if present */
        VkBaseOutStructure* node = (VkBaseOutStructure*)patched.pNext;
        while (node) {
            if (has_supported && node->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) {
                VkPhysicalDeviceFeatures2* f2 = (VkPhysicalDeviceFeatures2*)node;
                for (int i = 0; i < 55; ++i) {
                    if (f2->features.features[i] && !supported.features[i]) {
                        f2->features.features[i] = 0;
                        masked_count++;
                    }
                }
            } else if (node->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT) {
                VkPhysicalDeviceRobustness2FeaturesEXT* r2 = (VkPhysicalDeviceRobustness2FeaturesEXT*)node;
                r2->robustBufferAccess2 = 0;
                r2->robustImageAccess2 = 0;
                r2->nullDescriptor = 0;
            }
            node = node->pNext;
        }

        if (masked_count > 0 && g_cfg.verbose) {
            fprintf(stderr, "[DirectMetal-VKCompat] Masked %d unsupported VkPhysicalDeviceFeatures for MoltenVK\n", masked_count);
        }

        /* Also filter blocked device extensions from ppEnabledExtensionNames */
        if (!g_cfg.host_import &&
            patched.enabledExtensionCount > 0 &&
            patched.ppEnabledExtensionNames &&
            patched.enabledExtensionCount <= 256) {
            uint32_t filtered_ext_count = 0;
            for (uint32_t i = 0; i < patched.enabledExtensionCount; ++i) {
                if (!is_blocked_ext(patched.ppEnabledExtensionNames[i])) {
                    filtered_exts[filtered_ext_count++] = patched.ppEnabledExtensionNames[i];
                }
            }
            patched.enabledExtensionCount = filtered_ext_count;
            patched.ppEnabledExtensionNames = filtered_exts;
        }
    }

    VkResult res = next_create(physicalDevice, &patched, pAllocator, pDevice);
    if (res != VK_SUCCESS) return res;

    pthread_mutex_lock(&g_lock);
    if (g_dev_count < 64) {
        DevEntry* de = &g_devs[g_dev_count++];
        de->key = dispatch_key(*pDevice);
        de->next_gdpa = next_gdpa;
        de->next_destroy_device = (PFN_vkDestroyDevice)next_gdpa(*pDevice, "vkDestroyDevice");
        de->next_create_buffer = (PFN_vkCreateBuffer)next_gdpa(*pDevice, "vkCreateBuffer");
        de->next_create_image = (PFN_vkCreateImage)next_gdpa(*pDevice, "vkCreateImage");
        if (g_dev_count == 1) {
            sync_primary_dev_locked();
        }
    }
    pthread_mutex_unlock(&g_lock);
    return res;
}

static int strip_host_ext_mem_pnext(const void* orig_pnext, int32_t target_stype, const void** out_pnext) {
    const int host_import = g_cfg.host_import;
    const VkBaseInStructure* cur = (const VkBaseInStructure*)orig_pnext;
    int needs_strip = 0;
    while (cur) {
        if (cur->sType == target_stype) {
            const VkExternalMemoryBufferCreateInfo* em = (const VkExternalMemoryBufferCreateInfo*)cur;
            if (!host_import || (em->handleTypes & VK_HOST_EXTERNAL_HANDLE_MASK)) {
                needs_strip = 1;
                break;
            }
        }
        cur = cur->pNext;
    }
    if (!needs_strip) return 0;
    /* Unlink matching node(s) from the front; if embedded deeper, skip head */
    const VkBaseInStructure* head = (const VkBaseInStructure*)orig_pnext;
    while (head && head->sType == target_stype) {
        const VkExternalMemoryBufferCreateInfo* em = (const VkExternalMemoryBufferCreateInfo*)head;
        if (!host_import || (em->handleTypes & VK_HOST_EXTERNAL_HANDLE_MASK)) {
            head = head->pNext;
        } else {
            break;
        }
    }
    *out_pnext = head;
    return 1;
}

static VkResult dm_vkCreateBuffer(
    VkDevice device,
    const VkBufferCreateInfo* pCreateInfo,
    const void* pAllocator,
    void* pBuffer)
{
    PFN_vkCreateBuffer next_fn = NULL;
    void* k = dispatch_key(device);
    if (__builtin_expect(k != NULL && k == atomic_load_explicit(&g_primary_dev_key, memory_order_acquire), 1)) {
        next_fn = atomic_load_explicit(&g_primary_create_buffer, memory_order_relaxed);
    } else {
        pthread_mutex_lock(&g_lock);
        DevEntry* de = find_dev(device);
        if (de) next_fn = de->next_create_buffer;
        pthread_mutex_unlock(&g_lock);
    }
    if (!next_fn) return VK_ERROR_INITIALIZATION_FAILED;

    if (__builtin_expect(g_cfg.enabled && pCreateInfo && pCreateInfo->pNext != NULL, 0)) {
        const void* new_pnext = NULL;
        if (strip_host_ext_mem_pnext(pCreateInfo->pNext, VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO, &new_pnext)) {
            VkBufferCreateInfo patched = *pCreateInfo;
            patched.pNext = new_pnext;
            return next_fn(device, &patched, pAllocator, pBuffer);
        }
    }
    return next_fn(device, pCreateInfo, pAllocator, pBuffer);
}

static VkResult dm_vkCreateImage(
    VkDevice device,
    const VkImageCreateInfo* pCreateInfo,
    const void* pAllocator,
    void* pImage)
{
    PFN_vkCreateImage next_fn = NULL;
    void* k = dispatch_key(device);
    if (__builtin_expect(k != NULL && k == atomic_load_explicit(&g_primary_dev_key, memory_order_acquire), 1)) {
        next_fn = atomic_load_explicit(&g_primary_create_image, memory_order_relaxed);
    } else {
        pthread_mutex_lock(&g_lock);
        DevEntry* de = find_dev(device);
        if (de) next_fn = de->next_create_image;
        pthread_mutex_unlock(&g_lock);
    }
    if (!next_fn) return VK_ERROR_INITIALIZATION_FAILED;

    if (__builtin_expect(g_cfg.enabled && pCreateInfo && pCreateInfo->pNext != NULL, 0)) {
        const void* new_pnext = NULL;
        if (strip_host_ext_mem_pnext(pCreateInfo->pNext, VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, &new_pnext)) {
            VkImageCreateInfo patched = *pCreateInfo;
            patched.pNext = new_pnext;
            return next_fn(device, &patched, pAllocator, pImage);
        }
    }
    return next_fn(device, pCreateInfo, pAllocator, pImage);
}

static void dm_vkDestroyDevice(VkDevice device, const void* pAllocator) {
    PFN_vkDestroyDevice next_fn = NULL;
    pthread_mutex_lock(&g_lock);
    void* k = dispatch_key(device);
    for (int i = 0; i < g_dev_count; ++i) {
        if (g_devs[i].key == k) {
            next_fn = g_devs[i].next_destroy_device;
            g_devs[i] = g_devs[--g_dev_count];
            sync_primary_dev_locked();
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    if (next_fn) next_fn(device, pAllocator);
}

__attribute__((visibility("default")))
PFN_vkVoidFunction dm_vkGetDeviceProcAddr(VkDevice device, const char* pName) {
    if (!pName) return NULL;
    if (pName[0] == 'v' && pName[1] == 'k') {
        const char* sub = pName + 2;
        switch (sub[0]) {
            case 'C':
                if (g_cfg.enabled && sub[1] == 'r') {
                    if (strcmp(sub, "CreateBuffer") == 0) return (PFN_vkVoidFunction)dm_vkCreateBuffer;
                    if (strcmp(sub, "CreateImage") == 0) return (PFN_vkVoidFunction)dm_vkCreateImage;
                }
                break;
            case 'D':
                if (strcmp(sub, "DestroyDevice") == 0) return (PFN_vkVoidFunction)dm_vkDestroyDevice;
                break;
            case 'G':
                if (strcmp(sub, "GetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)dm_vkGetDeviceProcAddr;
                break;
            default:
                break;
        }
    }

    PFN_vkGetDeviceProcAddr next_gdpa = NULL;
    void* k = dispatch_key(device);
    if (__builtin_expect(k != NULL && k == atomic_load_explicit(&g_primary_dev_key, memory_order_acquire), 1)) {
        next_gdpa = atomic_load_explicit(&g_primary_gdpa, memory_order_relaxed);
    } else {
        pthread_mutex_lock(&g_lock);
        DevEntry* de = find_dev(device);
        if (de) next_gdpa = de->next_gdpa;
        pthread_mutex_unlock(&g_lock);
    }
    return next_gdpa ? next_gdpa(device, pName) : NULL;
}

__attribute__((visibility("default")))
PFN_vkVoidFunction dm_vkGetInstanceProcAddr(VkInstance instance, const char* pName) {
    if (!pName) return NULL;
    ensure_env_config();
    if (pName[0] == 'v' && pName[1] == 'k') {
        const char* sub = pName + 2;
        switch (sub[0]) {
            case 'C':
                if (strcmp(sub, "CreateInstance") == 0) return (PFN_vkVoidFunction)dm_vkCreateInstance;
                if (strcmp(sub, "CreateDevice") == 0) return (PFN_vkVoidFunction)dm_vkCreateDevice;
                break;
            case 'D':
                if (strcmp(sub, "DestroyInstance") == 0) return (PFN_vkVoidFunction)dm_vkDestroyInstance;
                break;
            case 'E':
                if (g_cfg.enabled && strcmp(sub, "EnumerateDeviceExtensionProperties") == 0) {
                    return (PFN_vkVoidFunction)dm_vkEnumerateDeviceExtensionProperties;
                }
                break;
            case 'G':
                if (strcmp(sub, "GetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)dm_vkGetInstanceProcAddr;
                if (strcmp(sub, "GetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)dm_vkGetDeviceProcAddr;
                if (g_cfg.enabled) {
                    if (strcmp(sub, "GetPhysicalDeviceFeatures") == 0) {
                        return (PFN_vkVoidFunction)dm_vkGetPhysicalDeviceFeatures;
                    }
                    if (strcmp(sub, "GetPhysicalDeviceFeatures2") == 0 ||
                        strcmp(sub, "GetPhysicalDeviceFeatures2KHR") == 0) {
                        return (PFN_vkVoidFunction)dm_vkGetPhysicalDeviceFeatures2;
                    }
                }
                break;
            default:
                break;
        }
    }

    pthread_mutex_lock(&g_lock);
    InstEntry* ie = find_inst(instance);
    PFN_vkGetInstanceProcAddr next_gipa = ie ? ie->next_gipa : NULL;
    pthread_mutex_unlock(&g_lock);
    return next_gipa ? next_gipa(instance, pName) : NULL;
}
