/*
 * DirectMetal D3D12 Placed-Resource Alignment Guard (d3d12.dll proxy)
 *
 * Forwards all 8 D3D12 exports to Mullion's d3d12core.dll / d3d12_real.dll and
 * intercepts ID3D12Device::CreatePlacedResource / CreatePlacedResource1 /
 * CreatePlacedResource2.
 *
 * For every spec-aligned call (HeapOffset % 65536 == 0) or any call Mullion
 * accepts, Mullion's real placed-resource path runs with zero overhead and
 * full heap aliasing.
 *
 * Only when Mullion returns E_INVALIDARG on a misaligned offset
 * (e.g. UE5 RDG transient heap sub-allocations at 32 KiB offset on macOS < 26.4),
 * the guard transparently falls back to CreateCommittedResource with matching
 * D3D12_HEAP_PROPERTIES so the title continues running cleanly on Metal 4
 * without crashing.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

#ifndef S_OK
#define S_OK ((HRESULT)0)
#endif
#ifndef E_INVALIDARG
#define E_INVALIDARG ((HRESULT)0x80070057)
#endif
#ifndef E_FAIL
#define E_FAIL ((HRESULT)0x80004005)
#endif

typedef struct {
    uint32_t Type;
    uint32_t CPUPageProperty;
    uint32_t MemoryPoolPreference;
    uint32_t CreationNodeMask;
    uint32_t VisibleNodeMask;
} DM_D3D12_HEAP_PROPERTIES;

typedef struct {
    uint64_t SizeInBytes;
    DM_D3D12_HEAP_PROPERTIES Properties;
    uint64_t Alignment;
    uint32_t Flags;
} DM_D3D12_HEAP_DESC;

/* D3D12_HEAP_FLAG_DENY_NON_RT_DS_TEXTURES | DENY_RT_DS_TEXTURES | DENY_BUFFERS */
#define DM_HEAP_FLAG_DENY_MASK 0x000001C0u

typedef HRESULT (WINAPI *PFN_D3D12CreateDevice)(void*, uint32_t, const GUID*, void**);
typedef HRESULT (WINAPI *PFN_D3D12GetInterface)(const GUID*, const GUID*, void**);
typedef HRESULT (WINAPI *PFN_D3D12GetDebugInterface)(const GUID*, void**);
typedef HRESULT (WINAPI *PFN_D3D12SerializeRootSignature)(const void*, uint32_t, void**, void**);
typedef HRESULT (WINAPI *PFN_D3D12SerializeVersionedRootSignature)(const void*, void**, void**);
typedef HRESULT (WINAPI *PFN_D3D12CreateRootSignatureDeserializer)(const void*, size_t, const GUID*, void**);
typedef HRESULT (WINAPI *PFN_D3D12CreateVersionedRootSignatureDeserializer)(const void*, size_t, const GUID*, void**);
typedef HRESULT (WINAPI *PFN_D3D12EnableExperimentalFeatures)(UINT, const GUID*, void*, UINT*);

/* ID3D12Heap::GetDesc (vtable slot 8) uses MSVC hidden-return-pointer ABI on x64/ARM64EC */
typedef DM_D3D12_HEAP_DESC* (WINAPI *PFN_Heap_GetDesc)(void* self, DM_D3D12_HEAP_DESC* outDesc);

/* ID3D12Device::CreateCommittedResource (vtable slot 27) */
typedef HRESULT (WINAPI *PFN_Dev_CreateCommittedResource)(
    void* self,
    const DM_D3D12_HEAP_PROPERTIES* pHeapProps,
    uint32_t HeapFlags,
    const void* pDesc,
    uint32_t InitialState,
    const void* pOptimizedClearValue,
    const GUID* riid,
    void** ppvResource);

/* ID3D12Device::CreatePlacedResource (vtable slot 29) */
typedef HRESULT (WINAPI *PFN_Dev_CreatePlacedResource)(
    void* self,
    void* pHeap,
    UINT64 HeapOffset,
    const void* pDesc,
    uint32_t InitialState,
    const void* pOptimizedClearValue,
    const GUID* riid,
    void** ppvResource);

/* ID3D12Device8::CreatePlacedResource1 (vtable slot 69) */
typedef HRESULT (WINAPI *PFN_Dev_CreatePlacedResource1)(
    void* self,
    void* pHeap,
    UINT64 HeapOffset,
    const void* pDesc1,
    uint32_t InitialState,
    const void* pOptimizedClearValue,
    const GUID* riid,
    void** ppvResource);

/* ID3D12Device8::CreateCommittedResource2 (vtable slot 68) */
typedef HRESULT (WINAPI *PFN_Dev_CreateCommittedResource2)(
    void* self,
    const DM_D3D12_HEAP_PROPERTIES* pHeapProps,
    uint32_t HeapFlags,
    const void* pDesc1,
    uint32_t InitialState,
    const void* pOptimizedClearValue,
    void* pProtectedSession,
    const GUID* riid,
    void** ppvResource);

/* ID3D12Device10::CreatePlacedResource2 (vtable slot 77) */
typedef HRESULT (WINAPI *PFN_Dev_CreatePlacedResource2)(
    void* self,
    void* pHeap,
    UINT64 HeapOffset,
    const void* pDesc1,
    uint32_t InitialLayout,
    const void* pOptimizedClearValue,
    UINT32 NumCastableFormats,
    const uint32_t* pCastableFormats,
    const GUID* riid,
    void** ppvResource);

/* ID3D12Device10::CreateCommittedResource3 (vtable slot 76) */
typedef HRESULT (WINAPI *PFN_Dev_CreateCommittedResource3)(
    void* self,
    const DM_D3D12_HEAP_PROPERTIES* pHeapProps,
    uint32_t HeapFlags,
    const void* pDesc1,
    uint32_t InitialLayout,
    const void* pOptimizedClearValue,
    void* pProtectedSession,
    UINT32 NumCastableFormats,
    const uint32_t* pCastableFormats,
    const GUID* riid,
    void** ppvResource);

static CRITICAL_SECTION g_cs;
static HMODULE g_real_d3d12 = NULL;
static PFN_Dev_CreatePlacedResource g_orig_CreatePlacedResource = NULL;
static PFN_Dev_CreatePlacedResource1 g_orig_CreatePlacedResource1 = NULL;
static PFN_Dev_CreatePlacedResource2 g_orig_CreatePlacedResource2 = NULL;
static PFN_Dev_CreateCommittedResource g_orig_CreateCommittedResource = NULL;
static PFN_Dev_CreateCommittedResource2 g_orig_CreateCommittedResource2 = NULL;
static PFN_Dev_CreateCommittedResource3 g_orig_CreateCommittedResource3 = NULL;
static volatile LONG g_fallback_count = 0;
static int g_vtable_patched = 0;
static int g_fast_fallback = 0;

#if defined(__GNUC__) || defined(__clang__)
#define DM_NOINLINE __attribute__((noinline))
#else
#define DM_NOINLINE
#endif

static void refresh_fast_fallback_env(void) {
    char buf[16];
    DWORD n = GetEnvironmentVariableA("DIRECTMETAL_D3D12_GUARD_FAST_FALLBACK", buf, sizeof(buf));
    if (n > 0 && n < sizeof(buf) &&
        (buf[0] == '1' || buf[0] == 'y' || buf[0] == 'Y' || buf[0] == 't' || buf[0] == 'T')) {
        g_fast_fallback = 1;
    } else {
        g_fast_fallback = 0;
    }
}

static HMODULE load_real_d3d12(void) {
    if (g_real_d3d12) return g_real_d3d12;
    EnterCriticalSection(&g_cs);
    if (!g_real_d3d12) {
        g_real_d3d12 = LoadLibraryA("d3d12_mullion.dll");
        if (!g_real_d3d12) {
            char sysdir[MAX_PATH];
            if (GetSystemDirectoryA(sysdir, MAX_PATH) > 0) {
                char path[MAX_PATH + 32];
                snprintf(path, sizeof(path), "%s\\d3d12_mullion.dll", sysdir);
                g_real_d3d12 = LoadLibraryA(path);
            }
        }
    }
    LeaveCriticalSection(&g_cs);
    return g_real_d3d12;
}

static DM_D3D12_HEAP_DESC get_heap_desc(void* pHeap) {
    DM_D3D12_HEAP_DESC hd;
    memset(&hd, 0, sizeof(hd));
    if (!pHeap) return hd;
    void** vtbl = *(void***)pHeap;
    PFN_Heap_GetDesc fn = (PFN_Heap_GetDesc)vtbl[8];
    if (fn) {
        fn(pHeap, &hd);
    }
    return hd;
}

static DM_NOINLINE HRESULT slow_CreatePlacedResource(
    void* self, void* pHeap, UINT64 HeapOffset, const void* pDesc,
    uint32_t InitialState, const void* pOptimizedClearValue,
    const GUID* riid, void** ppvResource)
{
    if (g_fast_fallback && self && pHeap && pDesc) {
        PFN_Dev_CreateCommittedResource fn = g_orig_CreateCommittedResource;
        if (!fn) {
            void** vtbl = *(void***)self;
            fn = (PFN_Dev_CreateCommittedResource)vtbl[27];
        }
        DM_D3D12_HEAP_DESC hd = get_heap_desc(pHeap);
        if (fn && hd.Properties.Type != 0) {
            uint32_t cleanFlags = hd.Flags & ~DM_HEAP_FLAG_DENY_MASK;
            HRESULT fb = fn(self, &hd.Properties, cleanFlags, pDesc, InitialState, pOptimizedClearValue, riid, ppvResource);
            if (fb >= 0) {
                LONG n = InterlockedIncrement(&g_fallback_count);
                if (n <= 3) {
                    fprintf(stderr, "[DirectMetal-D3D12Guard] Fast-promoted misaligned CreatePlacedResource (offset=%llu) -> CreateCommittedResource (#%ld)\n",
                            (unsigned long long)HeapOffset, (long)n);
                }
                return fb;
            }
        }
    }

    HRESULT hr = g_orig_CreatePlacedResource(self, pHeap, HeapOffset, pDesc, InitialState, pOptimizedClearValue, riid, ppvResource);
    if (hr == E_INVALIDARG && self && pHeap && pDesc) {
        PFN_Dev_CreateCommittedResource fn = g_orig_CreateCommittedResource;
        if (!fn) {
            void** vtbl = *(void***)self;
            fn = (PFN_Dev_CreateCommittedResource)vtbl[27];
        }
        DM_D3D12_HEAP_DESC hd = get_heap_desc(pHeap);
        if (fn && hd.Properties.Type != 0) {
            uint32_t cleanFlags = hd.Flags & ~DM_HEAP_FLAG_DENY_MASK;
            HRESULT fb = fn(self, &hd.Properties, cleanFlags, pDesc, InitialState, pOptimizedClearValue, riid, ppvResource);
            if (fb >= 0) {
                LONG n = InterlockedIncrement(&g_fallback_count);
                if (n <= 3) {
                    fprintf(stderr, "[DirectMetal-D3D12Guard] Promoted misaligned CreatePlacedResource (offset=%llu) -> CreateCommittedResource (#%ld)\n",
                            (unsigned long long)HeapOffset, (long)n);
                }
                return fb;
            }
        }
    }
    return hr;
}

static HRESULT WINAPI hook_CreatePlacedResource(
    void* self, void* pHeap, UINT64 HeapOffset, const void* pDesc,
    uint32_t InitialState, const void* pOptimizedClearValue,
    const GUID* riid, void** ppvResource)
{
    if (__builtin_expect((HeapOffset & 0xFFFFULL) == 0, 1)) {
        return g_orig_CreatePlacedResource(self, pHeap, HeapOffset, pDesc, InitialState, pOptimizedClearValue, riid, ppvResource);
    }
    return slow_CreatePlacedResource(self, pHeap, HeapOffset, pDesc, InitialState, pOptimizedClearValue, riid, ppvResource);
}

static DM_NOINLINE HRESULT slow_CreatePlacedResource1(
    void* self, void* pHeap, UINT64 HeapOffset, const void* pDesc1,
    uint32_t InitialState, const void* pOptimizedClearValue,
    const GUID* riid, void** ppvResource)
{
    if (g_fast_fallback && self && pHeap && pDesc1) {
        PFN_Dev_CreateCommittedResource2 fn = g_orig_CreateCommittedResource2;
        if (!fn) {
            void** vtbl = *(void***)self;
            fn = (PFN_Dev_CreateCommittedResource2)vtbl[68];
        }
        DM_D3D12_HEAP_DESC hd = get_heap_desc(pHeap);
        if (fn && hd.Properties.Type != 0) {
            uint32_t cleanFlags = hd.Flags & ~DM_HEAP_FLAG_DENY_MASK;
            HRESULT fb = fn(self, &hd.Properties, cleanFlags, pDesc1, InitialState, pOptimizedClearValue, NULL, riid, ppvResource);
            if (fb >= 0) {
                LONG n = InterlockedIncrement(&g_fallback_count);
                if (n <= 3) {
                    fprintf(stderr, "[DirectMetal-D3D12Guard] Fast-promoted misaligned CreatePlacedResource1 (offset=%llu) -> CreateCommittedResource2 (#%ld)\n",
                            (unsigned long long)HeapOffset, (long)n);
                }
                return fb;
            }
        }
    }

    HRESULT hr = g_orig_CreatePlacedResource1(self, pHeap, HeapOffset, pDesc1, InitialState, pOptimizedClearValue, riid, ppvResource);
    if (hr == E_INVALIDARG && self && pHeap && pDesc1) {
        PFN_Dev_CreateCommittedResource2 fn = g_orig_CreateCommittedResource2;
        if (!fn) {
            void** vtbl = *(void***)self;
            fn = (PFN_Dev_CreateCommittedResource2)vtbl[68];
        }
        DM_D3D12_HEAP_DESC hd = get_heap_desc(pHeap);
        if (fn && hd.Properties.Type != 0) {
            uint32_t cleanFlags = hd.Flags & ~DM_HEAP_FLAG_DENY_MASK;
            HRESULT fb = fn(self, &hd.Properties, cleanFlags, pDesc1, InitialState, pOptimizedClearValue, NULL, riid, ppvResource);
            if (fb >= 0) {
                LONG n = InterlockedIncrement(&g_fallback_count);
                if (n <= 3) {
                    fprintf(stderr, "[DirectMetal-D3D12Guard] Promoted misaligned CreatePlacedResource1 (offset=%llu) -> CreateCommittedResource2 (#%ld)\n",
                            (unsigned long long)HeapOffset, (long)n);
                }
                return fb;
            }
        }
    }
    return hr;
}

static HRESULT WINAPI hook_CreatePlacedResource1(
    void* self, void* pHeap, UINT64 HeapOffset, const void* pDesc1,
    uint32_t InitialState, const void* pOptimizedClearValue,
    const GUID* riid, void** ppvResource)
{
    if (__builtin_expect((HeapOffset & 0xFFFFULL) == 0, 1)) {
        return g_orig_CreatePlacedResource1(self, pHeap, HeapOffset, pDesc1, InitialState, pOptimizedClearValue, riid, ppvResource);
    }
    return slow_CreatePlacedResource1(self, pHeap, HeapOffset, pDesc1, InitialState, pOptimizedClearValue, riid, ppvResource);
}

static DM_NOINLINE HRESULT slow_CreatePlacedResource2(
    void* self, void* pHeap, UINT64 HeapOffset, const void* pDesc1,
    uint32_t InitialLayout, const void* pOptimizedClearValue,
    UINT32 NumCastableFormats, const uint32_t* pCastableFormats,
    const GUID* riid, void** ppvResource)
{
    if (g_fast_fallback && self && pHeap && pDesc1) {
        PFN_Dev_CreateCommittedResource3 fn = g_orig_CreateCommittedResource3;
        if (!fn) {
            void** vtbl = *(void***)self;
            fn = (PFN_Dev_CreateCommittedResource3)vtbl[76];
        }
        DM_D3D12_HEAP_DESC hd = get_heap_desc(pHeap);
        if (fn && hd.Properties.Type != 0) {
            uint32_t cleanFlags = hd.Flags & ~DM_HEAP_FLAG_DENY_MASK;
            HRESULT fb = fn(self, &hd.Properties, cleanFlags, pDesc1, InitialLayout, pOptimizedClearValue, NULL, NumCastableFormats, pCastableFormats, riid, ppvResource);
            if (fb >= 0) {
                LONG n = InterlockedIncrement(&g_fallback_count);
                if (n <= 3) {
                    fprintf(stderr, "[DirectMetal-D3D12Guard] Fast-promoted misaligned CreatePlacedResource2 (offset=%llu) -> CreateCommittedResource3 (#%ld)\n",
                            (unsigned long long)HeapOffset, (long)n);
                }
                return fb;
            }
        }
    }

    HRESULT hr = g_orig_CreatePlacedResource2(self, pHeap, HeapOffset, pDesc1, InitialLayout, pOptimizedClearValue, NumCastableFormats, pCastableFormats, riid, ppvResource);
    if (hr == E_INVALIDARG && self && pHeap && pDesc1) {
        PFN_Dev_CreateCommittedResource3 fn = g_orig_CreateCommittedResource3;
        if (!fn) {
            void** vtbl = *(void***)self;
            fn = (PFN_Dev_CreateCommittedResource3)vtbl[76];
        }
        DM_D3D12_HEAP_DESC hd = get_heap_desc(pHeap);
        if (fn && hd.Properties.Type != 0) {
            uint32_t cleanFlags = hd.Flags & ~DM_HEAP_FLAG_DENY_MASK;
            HRESULT fb = fn(self, &hd.Properties, cleanFlags, pDesc1, InitialLayout, pOptimizedClearValue, NULL, NumCastableFormats, pCastableFormats, riid, ppvResource);
            if (fb >= 0) {
                LONG n = InterlockedIncrement(&g_fallback_count);
                if (n <= 3) {
                    fprintf(stderr, "[DirectMetal-D3D12Guard] Promoted misaligned CreatePlacedResource2 (offset=%llu) -> CreateCommittedResource3 (#%ld)\n",
                            (unsigned long long)HeapOffset, (long)n);
                }
                return fb;
            }
        }
    }
    return hr;
}

static HRESULT WINAPI hook_CreatePlacedResource2(
    void* self, void* pHeap, UINT64 HeapOffset, const void* pDesc1,
    uint32_t InitialLayout, const void* pOptimizedClearValue,
    UINT32 NumCastableFormats, const uint32_t* pCastableFormats,
    const GUID* riid, void** ppvResource)
{
    if (__builtin_expect((HeapOffset & 0xFFFFULL) == 0, 1)) {
        return g_orig_CreatePlacedResource2(self, pHeap, HeapOffset, pDesc1, InitialLayout, pOptimizedClearValue, NumCastableFormats, pCastableFormats, riid, ppvResource);
    }
    return slow_CreatePlacedResource2(self, pHeap, HeapOffset, pDesc1, InitialLayout, pOptimizedClearValue, NumCastableFormats, pCastableFormats, riid, ppvResource);
}

static void patch_device_vtable(void* dev) {
    if (!dev) return;
    EnterCriticalSection(&g_cs);
    if (!g_vtable_patched) {
        void** vtbl = *(void***)dev;
        DWORD oldProt = 0;
        refresh_fast_fallback_env();
        if (vtbl[27]) {
            g_orig_CreateCommittedResource = (PFN_Dev_CreateCommittedResource)vtbl[27];
        }
        if (vtbl[68]) {
            g_orig_CreateCommittedResource2 = (PFN_Dev_CreateCommittedResource2)vtbl[68];
        }
        if (vtbl[76]) {
            g_orig_CreateCommittedResource3 = (PFN_Dev_CreateCommittedResource3)vtbl[76];
        }
        if (VirtualProtect(&vtbl[29], sizeof(void*) * 52, PAGE_READWRITE, &oldProt)) {
            if (vtbl[29] && vtbl[29] != (void*)hook_CreatePlacedResource) {
                g_orig_CreatePlacedResource = (PFN_Dev_CreatePlacedResource)vtbl[29];
                vtbl[29] = (void*)hook_CreatePlacedResource;
            }
            if (vtbl[69] && vtbl[69] != (void*)hook_CreatePlacedResource1) {
                g_orig_CreatePlacedResource1 = (PFN_Dev_CreatePlacedResource1)vtbl[69];
                vtbl[69] = (void*)hook_CreatePlacedResource1;
            }
            if (vtbl[77] && vtbl[77] != (void*)hook_CreatePlacedResource2) {
                g_orig_CreatePlacedResource2 = (PFN_Dev_CreatePlacedResource2)vtbl[77];
                vtbl[77] = (void*)hook_CreatePlacedResource2;
            }
            VirtualProtect(&vtbl[29], sizeof(void*) * 52, oldProt, &oldProt);
            g_vtable_patched = 1;
            fprintf(stderr, "[DirectMetal-D3D12Guard] Installed CreatePlacedResource/1/2 alignment guard on ID3D12Device vtable (fast_fallback=%d)\n",
                    g_fast_fallback);
        }
    }
    LeaveCriticalSection(&g_cs);
}

__declspec(dllexport) HRESULT WINAPI D3D12CreateDevice(void* pAdapter, uint32_t MinFL, const GUID* riid, void** ppDevice) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12CreateDevice fn = (PFN_D3D12CreateDevice)GetProcAddress(m, "D3D12CreateDevice");
    if (!fn) return E_FAIL;
    HRESULT hr = fn(pAdapter, MinFL, riid, ppDevice);
    if (hr >= 0 && ppDevice && *ppDevice) {
        patch_device_vtable(*ppDevice);
    }
    return hr;
}

/* CLSID_D3D12DeviceFactory = {114863bf-c386-4aee-b39d-8f0bbf067463} */
static const GUID DM_CLSID_D3D12DeviceFactory = {
    0x114863bf, 0xc386, 0x4aee, {0xb3, 0x9d, 0x8f, 0x0b, 0xbf, 0x06, 0x74, 0x63}
};

/* ID3D12DeviceFactory::CreateDevice (vtable slot 10) */
typedef HRESULT (WINAPI *PFN_Factory_CreateDevice)(
    void* self, void* pAdapter, uint32_t MinFL, const GUID* riid, void** ppvDevice);

static PFN_Factory_CreateDevice g_orig_Factory_CreateDevice = NULL;
static int g_factory_patched = 0;

static HRESULT WINAPI hook_Factory_CreateDevice(
    void* self, void* pAdapter, uint32_t MinFL, const GUID* riid, void** ppvDevice)
{
    HRESULT hr = g_orig_Factory_CreateDevice(self, pAdapter, MinFL, riid, ppvDevice);
    if (hr >= 0 && ppvDevice && *ppvDevice) {
        patch_device_vtable(*ppvDevice);
    }
    return hr;
}

static void patch_factory_vtable(void* factory) {
    if (!factory) return;
    EnterCriticalSection(&g_cs);
    if (!g_factory_patched) {
        void** vtbl = *(void***)factory;
        DWORD oldProt = 0;
        if (VirtualProtect(&vtbl[10], sizeof(void*), PAGE_READWRITE, &oldProt)) {
            if (vtbl[10] && vtbl[10] != (void*)hook_Factory_CreateDevice) {
                g_orig_Factory_CreateDevice = (PFN_Factory_CreateDevice)vtbl[10];
                vtbl[10] = (void*)hook_Factory_CreateDevice;
            }
            VirtualProtect(&vtbl[10], sizeof(void*), oldProt, &oldProt);
            g_factory_patched = 1;
        }
    }
    LeaveCriticalSection(&g_cs);
}

__declspec(dllexport) HRESULT WINAPI D3D12GetInterface(const GUID* rclsid, const GUID* riid, void** ppvDebug) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12GetInterface fn = (PFN_D3D12GetInterface)GetProcAddress(m, "D3D12GetInterface");
    if (!fn) return E_FAIL;
    HRESULT hr = fn(rclsid, riid, ppvDebug);
    if (hr >= 0 && rclsid && ppvDebug && *ppvDebug &&
        memcmp(rclsid, &DM_CLSID_D3D12DeviceFactory, sizeof(GUID)) == 0) {
        patch_factory_vtable(*ppvDebug);
    }
    return hr;
}

__declspec(dllexport) HRESULT WINAPI D3D12GetDebugInterface(const GUID* riid, void** ppvDebug) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12GetDebugInterface fn = (PFN_D3D12GetDebugInterface)GetProcAddress(m, "D3D12GetDebugInterface");
    return fn ? fn(riid, ppvDebug) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI D3D12SerializeRootSignature(const void* pRootSig, uint32_t Version, void** ppBlob, void** ppErrorBlob) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12SerializeRootSignature fn = (PFN_D3D12SerializeRootSignature)GetProcAddress(m, "D3D12SerializeRootSignature");
    return fn ? fn(pRootSig, Version, ppBlob, ppErrorBlob) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI D3D12SerializeVersionedRootSignature(const void* pRootSig, void** ppBlob, void** ppErrorBlob) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12SerializeVersionedRootSignature fn = (PFN_D3D12SerializeVersionedRootSignature)GetProcAddress(m, "D3D12SerializeVersionedRootSignature");
    return fn ? fn(pRootSig, ppBlob, ppErrorBlob) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI D3D12CreateRootSignatureDeserializer(const void* pSrcData, size_t SrcDataSize, const GUID* pInterface, void** ppDeserializer) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12CreateRootSignatureDeserializer fn = (PFN_D3D12CreateRootSignatureDeserializer)GetProcAddress(m, "D3D12CreateRootSignatureDeserializer");
    return fn ? fn(pSrcData, SrcDataSize, pInterface, ppDeserializer) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI D3D12CreateVersionedRootSignatureDeserializer(const void* pSrcData, size_t SrcDataSize, const GUID* pInterface, void** ppDeserializer) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12CreateVersionedRootSignatureDeserializer fn = (PFN_D3D12CreateVersionedRootSignatureDeserializer)GetProcAddress(m, "D3D12CreateVersionedRootSignatureDeserializer");
    return fn ? fn(pSrcData, SrcDataSize, pInterface, ppDeserializer) : E_FAIL;
}

__declspec(dllexport) HRESULT WINAPI D3D12EnableExperimentalFeatures(UINT NumFeatures, const GUID* pIIDs, void* pConfigStructs, UINT* pConfigStructSizes) {
    HMODULE m = load_real_d3d12();
    if (!m) return E_FAIL;
    PFN_D3D12EnableExperimentalFeatures fn = (PFN_D3D12EnableExperimentalFeatures)GetProcAddress(m, "D3D12EnableExperimentalFeatures");
    return fn ? fn(NumFeatures, pIIDs, pConfigStructs, pConfigStructSizes) : E_FAIL;
}

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved) {
    (void)hInst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&g_cs);
        refresh_fast_fallback_env();
    } else if (reason == DLL_PROCESS_DETACH) {
        DeleteCriticalSection(&g_cs);
    }
    return TRUE;
}
