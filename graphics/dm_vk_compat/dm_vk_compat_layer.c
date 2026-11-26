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

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static InstEntry g_insts[32];
static int g_inst_count = 0;
static DevEntry g_devs[64];
static int g_dev_count = 0;

static inline void* dispatch_key(void* obj) {
    return obj ? *(void**)obj : NULL;
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

static int advertise_fillmode_enabled(void) {
    const char* v = getenv("DM_VK_COMPAT_ADVERTISE_FILLMODE");
    return (v && v[0] == '1');
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
    if (advertise_fillmode_enabled()) {
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
    if (advertise_fillmode_enabled()) {
        pFeatures->features.features[VK_FEAT_IDX_FILL_MODE_NON_SOLID] = 1;
    }
}

static int host_import_passthrough_enabled(void) {
    const char* v = getenv("DM_VK_COMPAT_HOST_IMPORT");
    return (v && v[0] == '1');
}

static int is_blocked_ext(const char* name) {
    if (!name) return 0;
    if (host_import_passthrough_enabled()) return 0;
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
    if (!next_fn) return VK_ERROR_INITIALIZATION_FAILED;

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

    if (masked_count > 0 && getenv("DM_VK_COMPAT_VERBOSE")) {
        fprintf(stderr, "[DirectMetal-VKCompat] Masked %d unsupported VkPhysicalDeviceFeatures for MoltenVK\n", masked_count);
    }

    /* Also filter blocked device extensions from ppEnabledExtensionNames */
    const char* filtered_exts[256];
    uint32_t filtered_ext_count = 0;
    if (patched.enabledExtensionCount > 0 && patched.ppEnabledExtensionNames && patched.enabledExtensionCount <= 256) {
        for (uint32_t i = 0; i < patched.enabledExtensionCount; ++i) {
            if (!is_blocked_ext(patched.ppEnabledExtensionNames[i])) {
                filtered_exts[filtered_ext_count++] = patched.ppEnabledExtensionNames[i];
            }
        }
        patched.enabledExtensionCount = filtered_ext_count;
        patched.ppEnabledExtensionNames = filtered_exts;
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
    }
    pthread_mutex_unlock(&g_lock);
    return res;
}

static int strip_host_ext_mem_pnext(const void* orig_pnext, int32_t target_stype, const void** out_pnext) {
    const VkBaseInStructure* cur = (const VkBaseInStructure*)orig_pnext;
    int needs_strip = 0;
    while (cur) {
        if (cur->sType == target_stype) {
            const VkExternalMemoryBufferCreateInfo* em = (const VkExternalMemoryBufferCreateInfo*)cur;
            if (!host_import_passthrough_enabled() || (em->handleTypes & VK_HOST_EXTERNAL_HANDLE_MASK)) {
                needs_strip = 1;
                break;
            }
        }
        cur = cur->pNext;
    }
    if (!needs_strip) return 0;
    /* Unlink matching node(s) from the front; if embedded deeper, zero out host bits in place or skip head */
    const VkBaseInStructure* head = (const VkBaseInStructure*)orig_pnext;
    while (head && head->sType == target_stype) {
        const VkExternalMemoryBufferCreateInfo* em = (const VkExternalMemoryBufferCreateInfo*)head;
        if (!host_import_passthrough_enabled() || (em->handleTypes & VK_HOST_EXTERNAL_HANDLE_MASK)) {
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
    pthread_mutex_lock(&g_lock);
    DevEntry* de = find_dev(device);
    if (de) next_fn = de->next_create_buffer;
    pthread_mutex_unlock(&g_lock);
    if (!next_fn) return VK_ERROR_INITIALIZATION_FAILED;

    if (pCreateInfo && pCreateInfo->pNext) {
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
    pthread_mutex_lock(&g_lock);
    DevEntry* de = find_dev(device);
    if (de) next_fn = de->next_create_image;
    pthread_mutex_unlock(&g_lock);
    if (!next_fn) return VK_ERROR_INITIALIZATION_FAILED;

    if (pCreateInfo && pCreateInfo->pNext) {
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
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    if (next_fn) next_fn(device, pAllocator);
}

__attribute__((visibility("default")))
PFN_vkVoidFunction dm_vkGetDeviceProcAddr(VkDevice device, const char* pName) {
    if (!pName) return NULL;
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)dm_vkGetDeviceProcAddr;
    if (strcmp(pName, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)dm_vkDestroyDevice;
    if (strcmp(pName, "vkCreateBuffer") == 0) return (PFN_vkVoidFunction)dm_vkCreateBuffer;
    if (strcmp(pName, "vkCreateImage") == 0) return (PFN_vkVoidFunction)dm_vkCreateImage;
    pthread_mutex_lock(&g_lock);
    DevEntry* de = find_dev(device);
    PFN_vkGetDeviceProcAddr next_gdpa = de ? de->next_gdpa : NULL;
    pthread_mutex_unlock(&g_lock);
    return next_gdpa ? next_gdpa(device, pName) : NULL;
}

__attribute__((visibility("default")))
PFN_vkVoidFunction dm_vkGetInstanceProcAddr(VkInstance instance, const char* pName) {
    if (!pName) return NULL;
    if (strcmp(pName, "vkGetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)dm_vkGetInstanceProcAddr;
    if (strcmp(pName, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)dm_vkCreateInstance;
    if (strcmp(pName, "vkDestroyInstance") == 0) return (PFN_vkVoidFunction)dm_vkDestroyInstance;
    if (strcmp(pName, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)dm_vkCreateDevice;
    if (strcmp(pName, "vkGetPhysicalDeviceFeatures") == 0) return (PFN_vkVoidFunction)dm_vkGetPhysicalDeviceFeatures;
    if (strcmp(pName, "vkGetPhysicalDeviceFeatures2") == 0) return (PFN_vkVoidFunction)dm_vkGetPhysicalDeviceFeatures2;
    if (strcmp(pName, "vkGetPhysicalDeviceFeatures2KHR") == 0) return (PFN_vkVoidFunction)dm_vkGetPhysicalDeviceFeatures2;
    if (strcmp(pName, "vkEnumerateDeviceExtensionProperties") == 0) return (PFN_vkVoidFunction)dm_vkEnumerateDeviceExtensionProperties;
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)dm_vkGetDeviceProcAddr;
    pthread_mutex_lock(&g_lock);
    InstEntry* ie = find_inst(instance);
    PFN_vkGetInstanceProcAddr next_gipa = ie ? ie->next_gipa : NULL;
    pthread_mutex_unlock(&g_lock);
    return next_gipa ? next_gipa(instance, pName) : NULL;
}
