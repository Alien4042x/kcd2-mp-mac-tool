// Experimental exact-version KCD:MP application-only CPU frame bridge.
// DllMain stays passive. No Wine patches or integrity-check modifications.
#include "cpu_bridge.h"
#include "patch_guard.h"
#include <bcrypt.h>
#include <tlhelp32.h>
#include <cstdio>
#include <string>
#include <vector>
#include <algorithm>

namespace {
compat::FrameStore frames;
compat::CpuBridge bridge;
unsigned char *client = nullptr;
SRWLOCK init_lock = SRWLOCK_INIT;
bool active = false;
volatile LONG failed = 0;
bool native_loading_held = false;
struct Published { uint32_t ring; int32_t slot; uint64_t value; uint32_t width, height; };
static_assert(sizeof(Published) == 24);

void log_line(const char *message, DWORD code = 0) {
    wchar_t path[32768];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", path, DWORD(std::size(path)));
    if (!n || n + 32 >= std::size(path)) return;
    wcscat(path, L"\\KcdMp\\cef-compat.log");
    HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    char line[256];
    int size = std::snprintf(line, sizeof(line), "CEF_COMPAT|pid=%lu|%s|code=%lu\r\n", GetCurrentProcessId(), message, code);
    DWORD written = 0;
    if (size > 0) WriteFile(file, line, DWORD(size), &written, nullptr);
    CloseHandle(file);
}
void atomic_exchange8(volatile char *address, char value) { __atomic_exchange_n(address, value, __ATOMIC_SEQ_CST); }
void failure(HRESULT result) {
    if (!InterlockedExchange(&failed, 1)) log_line("bridge failed, native fallback", DWORD(result));
    if (client) {
        atomic_exchange8(reinterpret_cast<volatile char *>(client + target::pipeline_failed), 1);
        atomic_exchange8(reinterpret_cast<volatile char *>(client + target::shown), 0);
    }
}
bool open_frames(LUID, void *) {
    frames.clear();
    log_line("CPU frame producer opened");
    return InterlockedCompareExchange(&failed, 0, 0) == 0;
}
void paint_frames(const void *data, int w, int h) {
    if (!frames.paint(data, w, h, false)) failure(E_INVALIDARG);
}
void paint_popup(const void *data, int w, int h) {
    if (!frames.paint(data, w, h, true)) failure(E_INVALIDARG);
}
void popup_rect(int x, int y, int w, int h) { frames.popup_rect(x, y, w, h); }
void popup_show(bool shown) { frames.popup_show(shown); }
bool latest(Published &published) {
    if (InterlockedCompareExchange(&failed, 0, 0)) return false;
    UINT w = 0, h = 0; uint64_t sequence = 0;
    if (!frames.size(w, h, sequence)) return false;
    published = {1, 0, sequence, w, h};
    return true;
}
bool native_loading_cover() { return false; }
void retain_native_loading() {
    // Original client API, verified against this exact image. No additional
    // entry jump: only replace its atomic loading-cover callback on this Mac.
    auto set_probe = reinterpret_cast<void (*)(bool (*)())>(client + target::set_loading_cover_probe);
    set_probe(&native_loading_cover);
}
void record(ID3D12GraphicsCommandList *commands, unsigned w, unsigned h) {
    atomic_exchange8(reinterpret_cast<volatile char *>(client + target::shown), 0);
    if (InterlockedCompareExchange(&failed, 0, 0) || !__atomic_load_n(client + target::enabled, __ATOMIC_ACQUIRE)) return;
    retain_native_loading();
    auto loading = reinterpret_cast<bool (*)()>(client + target::loading_visible);
    auto wants_paint = reinterpret_cast<bool (*)()>(client + target::loading_wants_paint);
    // Keep the web loading's final fade out of the game too. The engine clears
    // wants_paint when that drawer leaves, before in-game frames resume.
    bool hold = loading() || wants_paint();
    if (hold != native_loading_held) {
        native_loading_held = hold;
        log_line(hold ? "original native loading retained locally" : "loading ended, normal CEF composition resumed");
    }
    if (hold) return;
    auto info = reinterpret_cast<const unsigned char *(*)()>(client + target::render_info)();
    if (!info) return;
    ID3D12Device *device = nullptr; DXGI_FORMAT format;
    std::memcpy(&device, info, sizeof(device));
    std::memcpy(&format, info + 0x24, sizeof(format));
    if (bridge.record(frames, device, format, commands, w, h)) {
        atomic_exchange8(reinterpret_cast<volatile char *>(client + target::shown), 1);
        auto count = InterlockedIncrement(reinterpret_cast<volatile LONG *>(client + target::frames_drawn));
        if (count == 1) log_line("first overlay draw recorded");
    } else if (bridge.failed()) failure(bridge.error());
    // The client records ImGui next. Its backend explicitly rebinds its own
    // descriptor heap, root signature, PSO and viewport before any ImGui draw.
}
void before_submit(ID3D12CommandQueue *) { /* Same command list needs no cross-device wait. */ }
void after_submit(ID3D12CommandQueue *queue) {
    if (!bridge.submitted(queue)) failure(bridge.error());
}
void renderer_reset() {
    // Confirmed caller invokes hooks::wait_for_gpu before this callback.
    bridge.reset_after_gpu_idle();
    atomic_exchange8(reinterpret_cast<volatile char *>(client + target::shown), 0);
    log_line("renderer reset after client GPU wait");
}
std::array<void *, compat::patch_count> destinations() {
    return {reinterpret_cast<void *>(&open_frames), reinterpret_cast<void *>(&paint_frames),
        reinterpret_cast<void *>(&paint_popup), reinterpret_cast<void *>(&popup_rect),
        reinterpret_cast<void *>(&popup_show), reinterpret_cast<void *>(&latest),
        reinterpret_cast<void *>(&record), reinterpret_cast<void *>(&before_submit),
        reinterpret_cast<void *>(&after_submit), reinterpret_cast<void *>(&renderer_reset)};
}
std::wstring final_path(const wchar_t *path) {
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return {};
    wchar_t result[32768];
    DWORD n = GetFinalPathNameByHandleW(file, result, DWORD(std::size(result)), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(file);
    if (!n || n >= std::size(result)) return {};
    return result;
}
bool exact_process() {
    wchar_t path[32768];
    DWORD n = GetModuleFileNameW(nullptr, path, DWORD(std::size(path)));
    if (!n || n >= std::size(path)) return false;
    auto actual = final_path(path), expected = final_path(target::process_path);
    return !actual.empty() && !expected.empty() && _wcsicmp(actual.c_str(), expected.c_str()) == 0;
}
bool hash_matches(const wchar_t *path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
    bool okay = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) == 0;
    if (okay) okay = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) == 0;
    unsigned char data[65536]; DWORD read = 0;
    while (okay) {
        if (!ReadFile(file, data, DWORD(sizeof(data)), &read, nullptr)) { okay = false; break; }
        if (!read) break;
        if (BCryptHashData(hash, data, read, 0) != 0) { okay = false; break; }
    }
    unsigned char digest[32] = {}; char hex[65] = {};
    if (okay) okay = BCryptFinishHash(hash, digest, 32, 0) == 0;
    for (unsigned i = 0; i < 32; ++i) std::snprintf(hex + 2*i, 3, "%02x", digest[i]);
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    return okay && std::strcmp(hex, target::client_sha) == 0;
}
class FrozenThreads {
    std::vector<HANDLE> handles_;
    size_t suspended_ = 0;
public:
    DWORD freeze(unsigned char *base) {
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snapshot == INVALID_HANDLE_VALUE) return GetLastError();
        THREADENTRY32 entry = {}; entry.dwSize = sizeof(entry);
        if (!Thread32First(snapshot, &entry)) { DWORD code = GetLastError(); CloseHandle(snapshot); return code; }
        do {
            if (entry.th32OwnerProcessID != GetCurrentProcessId() || entry.th32ThreadID == GetCurrentThreadId()) continue;
            HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT, FALSE, entry.th32ThreadID);
            if (!thread) { DWORD code = GetLastError(); CloseHandle(snapshot); return code; }
            handles_.push_back(thread);
        } while (Thread32Next(snapshot, &entry));
        CloseHandle(snapshot);
        // All allocation and enumeration precede suspension.
        for (auto thread : handles_) {
            if (SuspendThread(thread) == DWORD(-1)) return GetLastError();
            ++suspended_;
            CONTEXT context = {}; context.ContextFlags = CONTEXT_CONTROL;
            if (!GetThreadContext(thread, &context)) return GetLastError();
            if (compat::ip_in_candidate(context.Rip, base)) return ERROR_BUSY;
            // Refuse a caller inside a candidate too, e.g. CreateDevice has
            // entered a system DLL while its frame-open caller remains active.
            MEMORY_BASIC_INFORMATION stack = {};
            if (!VirtualQuery(reinterpret_cast<void *>(context.Rsp), &stack, sizeof(stack)) ||
                stack.State != MEM_COMMIT || (stack.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return ERROR_BUSY;
            auto end = std::min(uintptr_t(stack.BaseAddress) + stack.RegionSize, uintptr_t(context.Rsp) + 65536);
            for (auto p = uintptr_t(context.Rsp); p + sizeof(uintptr_t) <= end; p += sizeof(uintptr_t)) {
                uintptr_t value = 0; std::memcpy(&value, reinterpret_cast<void *>(p), sizeof(value));
                if (compat::ip_in_candidate(value, base)) return ERROR_BUSY;
            }
        }
        return 0;
    }
    ~FrozenThreads() {
        for (size_t i = suspended_; i > 0; --i) ResumeThread(handles_[i-1]);
        for (auto thread : handles_) CloseHandle(thread);
    }
};
// Tests can substitute API failures in their own executable. No such control
// or export is present in the production helper.
#ifdef KCDMP_ADAPTER_PROBE
int test_flush_failures = 0;
#endif
BOOL flush_code(unsigned char *base) {
#ifdef KCDMP_ADAPTER_PROBE
    if (test_flush_failures > 0) { --test_flush_failures; SetLastError(ERROR_WRITE_FAULT); return FALSE; }
#endif
    return FlushInstructionCache(GetCurrentProcess(), base, target::image_size);
}
DWORD apply_patch_set(unsigned char *base, const compat::PatchBytes &patches, bool *remaining = nullptr) {
    if (remaining) *remaining = false;
    // Capture page protections before changing ANY page. Several entries can
    // share a page, so a later query must not mistake our RWX for the original.
    std::array<DWORD, compat::patch_count> original = {};
    for (size_t i = 0; i < compat::patch_count; ++i) {
        MEMORY_BASIC_INFORMATION page = {};
        auto *address = base + target::entries[i].rva;
        if (!VirtualQuery(address, &page, sizeof(page)) || page.State != MEM_COMMIT || page.Type != MEM_IMAGE ||
            (page.Protect & (PAGE_GUARD | PAGE_NOACCESS)) || !(page.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE))) return ERROR_INVALID_ADDRESS;
        original[i] = page.Protect;
    }
    FrozenThreads frozen;
    DWORD result = frozen.freeze(base);
    if (result) return result;
    if (*reinterpret_cast<void **>(base + target::frame_device)) return ERROR_BUSY;
    bool already = false;
    result = compat::validate_image(base, target::image_size, patches, already);
    if (result || already) { if (remaining) *remaining = already; return result; }
    size_t prepared = 0;
    for (; prepared < compat::patch_count; ++prepared) {
        DWORD ignored = 0;
        if (!VirtualProtect(base + target::entries[prepared].rva, 14, PAGE_EXECUTE_READWRITE, &ignored)) { result = GetLastError(); break; }
    }
    bool written = prepared == compat::patch_count;
    if (written) {
        for (size_t i = 0; i < compat::patch_count; ++i) std::memcpy(base + target::entries[i].rva, patches[i].data(), 14);
        if (!flush_code(base)) result = GetLastError();
    }
    bool restored = true;
    for (size_t i = prepared; i > 0; --i) {
        DWORD ignored = 0;
        restored &= VirtualProtect(base + target::entries[i-1].rva, 14, original[i-1], &ignored) != FALSE;
    }
    if (!restored && !result) result = ERROR_INVALID_ACCESS;
    if (written && result) {
        // Transactional rollback occurs while all target threads stay stopped.
        for (size_t i = 0; i < compat::patch_count; ++i) {
            DWORD ignored = 0;
            if (VirtualProtect(base + target::entries[i].rva, 14, PAGE_EXECUTE_READWRITE, &ignored))
                std::memcpy(base + target::entries[i].rva, target::entries[i].bytes, 14);
        }
        flush_code(base);
        for (size_t i = compat::patch_count; i > 0; --i) {
            DWORD ignored = 0;
            VirtualProtect(base + target::entries[i-1].rva, 14, original[i-1], &ignored);
        }
    }
    bool any_remaining = false;
    for (size_t i = 0; i < compat::patch_count; ++i)
        any_remaining |= std::memcmp(base + target::entries[i].rva, target::entries[i].bytes, 14) != 0;
    if (remaining) *remaining = any_remaining;
    return result;
}
DWORD initialize() {
    if (!exact_process()) return ERROR_ACCESS_DENIED;
    if (!GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version")) return ERROR_NOT_SUPPORTED;
    auto module = GetModuleHandleW(L"KcdMp_client.dll");
    if (!module) return ERROR_MOD_NOT_FOUND;
    wchar_t path[32768];
    if (!GetModuleFileNameW(module, path, DWORD(std::size(path)))) return GetLastError();
    auto expected = std::wstring(target::process_path);
    expected = expected.substr(0, expected.find_last_of(L'\\') + 1) + L"KcdMp_client.dll";
    auto actual_path = final_path(path), expected_path = final_path(expected.c_str());
    if (actual_path.empty() || expected_path.empty() || _wcsicmp(actual_path.c_str(), expected_path.c_str())) return ERROR_ACCESS_DENIED;
    if (!hash_matches(path)) return ERROR_REVISION_MISMATCH;
    auto base = reinterpret_cast<unsigned char *>(module);
    auto patches = compat::jumps(destinations());
    bool already = false;
    DWORD result = compat::validate_image(base, target::image_size, patches, already);
    if (result) return result;
    if (already) return active ? ERROR_SUCCESS : ERROR_INVALID_DATA;
    if (active) return ERROR_INVALID_DATA;
    // Must install before CEF startup. A late attach refuses cleanly.
    if (GetModuleHandleW(L"libcef.dll")) return ERROR_BUSY;
    // Entry jumps must never outlive their destination DLL.
    HMODULE pinned = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&initialize), &pinned)) return GetLastError();
    client = base;
    bool remaining = false;
    result = apply_patch_set(base, patches, &remaining);
    if (!result) { active = true; retain_native_loading(); }
    else if (remaining) {
        // Keep callback context alive if the OS could not complete rollback.
        active = true;
        failure(HRESULT_FROM_WIN32(result));
        atomic_exchange8(reinterpret_cast<volatile char *>(client + target::enabled), 0);
    } else client = nullptr;
    return result;
}
}
extern "C" __declspec(dllexport) DWORD WINAPI KcdMpCefCompatInitialize(void *) {
    AcquireSRWLockExclusive(&init_lock);
    DWORD code;
    try { code = initialize(); }
    catch (...) { code = ERROR_UNHANDLED_EXCEPTION; }
    ReleaseSRWLockExclusive(&init_lock);
    log_line(code ? "initialization refused" : "active, client file unchanged", code);
    return code;
}
BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }
