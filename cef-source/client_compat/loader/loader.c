#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>

#include "identity.h"
#define WAIT_MS 10000

static uintptr_t remote_module(DWORD pid, const wchar_t *path, DWORD *image_size) {
    HANDLE snapshot = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 10; ++attempt) {
        snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
        if (snapshot != INVALID_HANDLE_VALUE || GetLastError() != ERROR_BAD_LENGTH) break;
        Sleep(10);
    }
    if (snapshot == INVALID_HANDLE_VALUE) { error(L"module snapshot"); return 0; }
    MODULEENTRY32W entry = { .dwSize = sizeof(entry) };
    uintptr_t result = 0;
    if (!Module32FirstW(snapshot, &entry)) { error(L"Module32FirstW"); CloseHandle(snapshot); return 0; }
    do {
        wchar_t module_path[PATH_CAP];
        if (canonical(entry.szExePath, module_path) && same_path(module_path, path)) {
            result = (uintptr_t)entry.modBaseAddr;
            if (image_size) *image_size = entry.modBaseSize;
            break;
        }
    } while (Module32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return result;
}

static uintptr_t remote_loadlibrary(DWORD pid) {
    FARPROC proc = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
    HMODULE owner = NULL; MODULEINFO info; wchar_t local_path[PATH_CAP], owner_path[PATH_CAP];
    if (!proc || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCWSTR)(uintptr_t)proc, &owner) ||
        !GetModuleInformation(GetCurrentProcess(), owner, &info, sizeof(info)) ||
        !GetModuleFileNameW(owner, local_path, PATH_CAP) || !canonical(local_path, owner_path)) {
        error(L"resolve LoadLibraryW owner"); return 0;
    }
    uintptr_t rva = (uintptr_t)proc - (uintptr_t)info.lpBaseOfDll;
    DWORD remote_size = 0;
    uintptr_t remote_base = remote_module(pid, owner_path, &remote_size);
    if (!remote_base || rva >= info.SizeOfImage || remote_size != info.SizeOfImage) {
        fwprintf(stderr, L"loader: refused LoadLibraryW owning-module mismatch\n"); return 0;
    }
    wprintf(L"loader: LoadLibraryW owner=%ls rva=0x%llx remote=0x%llx\n", owner_path,
        (unsigned long long)rva, (unsigned long long)(remote_base + rva));
    return remote_base + rva;
}

static int bounded_thread(HANDLE process, uintptr_t function, void *argument, const wchar_t *label, DWORD *result, int *finished) {
    *finished = 0;
    HANDLE thread = CreateRemoteThread(process, NULL, 0, (LPTHREAD_START_ROUTINE)function, argument, 0, NULL);
    if (!thread) { error(L"CreateRemoteThread"); *finished = 1; return 0; }
    wprintf(L"loader: %ls remote thread started\n", label); fflush(stdout);
    DWORD wait = WaitForSingleObject(thread, WAIT_MS);
    if (wait != WAIT_OBJECT_0) {
        if (wait == WAIT_TIMEOUT) fwprintf(stderr, L"loader: %ls timed out after %d ms. Thread may still finish.\n", label, WAIT_MS);
        else error(L"WaitForSingleObject");
        CloseHandle(thread); return 0;
    }
    *finished = 1;
    int ok = GetExitCodeThread(thread, result) != FALSE;
    if (!ok) error(L"GetExitCodeThread");
    CloseHandle(thread); return ok;
}

static uintptr_t init_rva(const wchar_t *dll, DWORD *image_size) {
    HMODULE local = LoadLibraryExW(dll, NULL, DONT_RESOLVE_DLL_REFERENCES);
    if (!local) { error(L"map init export"); return 0; }
    MODULEINFO info; uintptr_t result = 0;
    FARPROC proc = GetProcAddress(local, "KcdMpCefCompatInitialize");
    if (!proc || !GetModuleInformation(GetCurrentProcess(), local, &info, sizeof(info))) {
        error(L"KcdMpCefCompatInitialize export");
    } else {
        uintptr_t address = (uintptr_t)proc, base = (uintptr_t)info.lpBaseOfDll;
        IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
        IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
        IMAGE_DATA_DIRECTORY exports = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
        if (address >= base && address - base < info.SizeOfImage &&
            !(address - base >= exports.VirtualAddress && address - base < (uintptr_t)exports.VirtualAddress + exports.Size)) {
            result = address - base; *image_size = info.SizeOfImage;
        } else fwprintf(stderr, L"loader: refused forwarded or foreign init export\n");
    }
    FreeLibrary(local);
    return result;
}

int wmain(int argc, wchar_t **argv) {
    DWORD pid = 0; const wchar_t *image_arg = NULL, *dll_arg = NULL; int initialise = 0;
    for (int i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--init") == 0) initialise = 1;
        else if (i + 1 < argc && wcscmp(argv[i], L"--pid") == 0) {
            wchar_t *end; unsigned long value = wcstoul(argv[++i], &end, 10);
            if (*end || !value) { fwprintf(stderr, L"loader: invalid PID\n"); return 2; }
            pid = value;
        } else if (i + 1 < argc && wcscmp(argv[i], L"--image") == 0) image_arg = argv[++i];
        else if (i + 1 < argc && wcscmp(argv[i], L"--dll") == 0) dll_arg = argv[++i];
        else { fwprintf(stderr, L"loader: unrecognised or incomplete argument: %ls\n", argv[i]); return 2; }
    }
    if (!pid || !image_arg || !dll_arg || pid == GetCurrentProcessId()) {
        fwprintf(stderr, L"usage: kcdmp_compat_loader.exe --pid PID --image FULL_EXE_PATH --dll FULL_DLL_PATH [--init]\n"); return 2;
    }
    wchar_t image[PATH_CAP], dll[PATH_CAP];
    if (!canonical(image_arg, image) || !canonical(dll_arg, dll)) return 3;
    if (!amd64_pe(image, 0) || !amd64_pe(dll, 1)) return 4;
    HANDLE query = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
    if (!query) { error(L"OpenProcess identity"); return 5; }
    if (!process_path(query, image) || !target_amd64(query) || WaitForSingleObject(query, 0) != WAIT_TIMEOUT) {
        CloseHandle(query); return 6;
    }
    FILETIME created, exited, kernel, user;
    if (!GetProcessTimes(query, &created, &exited, &kernel, &user)) { error(L"GetProcessTimes identity"); CloseHandle(query); return 6; }
    DWORD rights = PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ | SYNCHRONIZE;
    HANDLE process = OpenProcess(rights, FALSE, pid);
    FILETIME again;
    if (!process) { error(L"OpenProcess loader"); CloseHandle(query); return 7; }
    if (!GetProcessTimes(process, &again, &exited, &kernel, &user) || CompareFileTime(&created, &again) ||
        !process_path(process, image) || WaitForSingleObject(process, 0) != WAIT_TIMEOUT) {
        fwprintf(stderr, L"loader: refused changed or terminated process\n"); CloseHandle(query); CloseHandle(process); return 7;
    }
    CloseHandle(query);
    wprintf(L"loader: verified pid=%lu image=%ls dll=%ls init=%ls\n", pid, image, dll, initialise ? L"yes" : L"no");
    uintptr_t base = remote_module(pid, dll, NULL);
    if (!base) {
        uintptr_t load = remote_loadlibrary(pid);
        if (!load) { CloseHandle(process); return 8; }
        SIZE_T bytes = (wcslen(dll) + 1) * sizeof(wchar_t), written = 0;
        void *remote_path = VirtualAllocEx(process, NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!remote_path) { error(L"VirtualAllocEx path"); CloseHandle(process); return 9; }
        if (!WriteProcessMemory(process, remote_path, dll, bytes, &written) || written != bytes) {
            error(L"WriteProcessMemory path"); VirtualFreeEx(process, remote_path, 0, MEM_RELEASE); CloseHandle(process); return 10;
        }
        DWORD result = 0; int finished = 0;
        int loaded = bounded_thread(process, load, remote_path, L"LoadLibraryW", &result, &finished);
        if (finished) VirtualFreeEx(process, remote_path, 0, MEM_RELEASE);
        else fwprintf(stderr, L"loader: remote UTF-16 path retained until target exit to avoid a late-thread use-after-free\n");
        if (!loaded) { CloseHandle(process); return 11; }
        base = remote_module(pid, dll, NULL);
        wprintf(L"loader: LoadLibraryW thread_exit=0x%08lx module=0x%llx\n", result, (unsigned long long)base);
        if (!base) { fwprintf(stderr, L"loader: DLL was not present after LoadLibraryW. Remote loader return is only 32 bits.\n"); CloseHandle(process); return 12; }
    } else wprintf(L"loader: DLL already loaded, no additional LoadLibrary call\n");
    if (initialise) {
        DWORD local_size = 0, remote_size = 0;
        uintptr_t rva = init_rva(dll, &local_size);
        base = remote_module(pid, dll, &remote_size);
        if (!rva || !base || local_size != remote_size || rva >= remote_size) { CloseHandle(process); return 13; }
        wprintf(L"loader: init export=KcdMpCefCompatInitialize rva=0x%llx remote=0x%llx argument=NULL\n",
            (unsigned long long)rva, (unsigned long long)(base + rva));
        DWORD result = 0; int finished = 0;
        if (!bounded_thread(process, base + rva, NULL, L"KcdMpCefCompatInitialize", &result, &finished)) { CloseHandle(process); return 14; }
        wprintf(L"loader: init_exit=0x%08lx\n", result);
        if (result != ERROR_SUCCESS) {
            SetLastError(result); error(L"KcdMpCefCompatInitialize"); CloseHandle(process); return 15;
        }
    }
    CloseHandle(process);
    wprintf(L"loader: completed\n");
    return 0;
}
