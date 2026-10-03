#include "identity.h"
#include <stdlib.h>

#define WATCH_MS 120000
#define POLL_MS 25
#define LOADER_MS 25000
#define COMMAND_CAP (PATH_CAP * 3 + 256)

static const wchar_t *basename(const wchar_t *path) {
    const wchar_t *last = wcsrchr(path, L'\\');
    return last ? last + 1 : path;
}
static int absolute(const wchar_t *path) {
    size_t size = wcslen(path);
    return (size >= 2 && path[0] == L'\\' && path[1] == L'\\') ||
        (size >= 3 && ((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) &&
         path[1] == L':' && (path[2] == L'\\' || path[2] == L'/'));
}

static int exact_target(const wchar_t *image, DWORD *pid) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) { error(L"process snapshot"); return -1; }
    PROCESSENTRY32W entry = { .dwSize = sizeof(entry) };
    int matches = 0;
    if (!Process32FirstW(snapshot, &entry)) { error(L"Process32FirstW"); CloseHandle(snapshot); return -1; }
    do {
        if (!same_path(entry.szExeFile, basename(image))) continue;
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, entry.th32ProcessID);
        if (!process) { error(L"OpenProcess target discovery"); CloseHandle(snapshot); return -1; }
        wchar_t path[PATH_CAP], full[PATH_CAP]; DWORD length = PATH_CAP;
        BOOL okay = QueryFullProcessImageNameW(process, 0, path, &length);
        BOOL exited = WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
        CloseHandle(process);
        if (exited) continue;
        if (!okay) { error(L"QueryFullProcessImageNameW discovery"); CloseHandle(snapshot); return -1; }
        if (!canonical(path, full)) { CloseHandle(snapshot); return -1; }
        if (same_path(image, full)) { ++matches; *pid = entry.th32ProcessID; }
    } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return matches;
}

static int modules(DWORD pid, int *client, int *cef) {
    *client = *cef = 0;
    HANDLE snapshot = INVALID_HANDLE_VALUE;
    for (int i = 0; i < 8; ++i) {
        snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
        if (snapshot != INVALID_HANDLE_VALUE || GetLastError() != ERROR_BAD_LENGTH) break;
        Sleep(2);
    }
    if (snapshot == INVALID_HANDLE_VALUE) {
        DWORD code = GetLastError();
        if (code == ERROR_BAD_LENGTH || code == ERROR_PARTIAL_COPY) return 2;
        error(L"watch module snapshot"); return 0;
    }
    MODULEENTRY32W entry = { .dwSize = sizeof(entry) };
    if (!Module32FirstW(snapshot, &entry)) {
        DWORD code = GetLastError(); CloseHandle(snapshot);
        if (code == ERROR_NO_MORE_FILES || code == ERROR_PARTIAL_COPY) return 2;
        error(L"watch Module32FirstW"); return 0;
    }
    do {
        if (same_path(entry.szModule, L"KcdMp_client.dll")) *client = 1;
        if (same_path(entry.szModule, L"libcef.dll")) *cef = 1;
    } while (Module32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return 1;
}

/* Windows CRT argument quoting. Double trailing backslashes and those before quotes. */
static int quote(wchar_t *command, size_t *used, const wchar_t *word) {
#define ADD(ch) do { if (*used + 1 >= COMMAND_CAP) return 0; command[(*used)++] = (ch); } while (0)
    if (*used) ADD(L' ');
    ADD(L'"');
    while (*word) {
        size_t slashes = 0;
        while (*word == L'\\') { ++slashes; ++word; }
        size_t count = (*word == L'"' || !*word) ? slashes * 2 : slashes;
        for (size_t i = 0; i < count; ++i) ADD(L'\\');
        if (*word == L'"') ADD(L'\\');
        if (*word) ADD(*word++);
    }
    ADD(L'"'); command[*used] = L'\0';
#undef ADD
    return 1;
}

static int ready_marker(const wchar_t *path) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) { error(L"create ready marker"); return 0; }
    const char text[] = "ready: preflight passed, no existing target process\r\n";
    DWORD bytes = 0;
    BOOL okay = WriteFile(file, text, sizeof(text) - 1, &bytes, NULL) && bytes == sizeof(text) - 1;
    if (okay) okay = FlushFileBuffers(file);
    CloseHandle(file);
    if (!okay) { error(L"write ready marker"); DeleteFileW(path); return 0; }
    return 1;
}

static int start_loader(const wchar_t *loader, DWORD pid, const wchar_t *image, const wchar_t *dll, HANDLE target) {
    wchar_t command[COMMAND_CAP], number[32]; size_t used = 0;
    swprintf(number, 32, L"%lu", pid);
    const wchar_t *words[] = {loader, L"--pid", number, L"--image", image, L"--dll", dll, L"--init"};
    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); ++i) {
        if (!quote(command, &used, words[i])) { fwprintf(stderr, L"watcher: loader command too long\n"); return 20; }
    }
    STARTUPINFOW startup = { .cb = sizeof(startup) }; PROCESS_INFORMATION child = {};
    if (!CreateProcessW(loader, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child)) {
        error(L"CreateProcessW loader"); return 21;
    }
    CloseHandle(child.hThread);
    wprintf(L"watcher: loader started for Windows PID %lu\n", pid); fflush(stdout);
    ULONGLONG until = GetTickCount64() + LOADER_MS;
    for (;;) {
        DWORD wait = WaitForSingleObject(child.hProcess, POLL_MS);
        if (wait == WAIT_OBJECT_0) {
            DWORD result = 0;
            if (!GetExitCodeProcess(child.hProcess, &result)) { error(L"GetExitCodeProcess loader"); CloseHandle(child.hProcess); return 22; }
            CloseHandle(child.hProcess);
            wprintf(L"watcher: loader_exit=%lu\n", result);
            return result == 0 ? 0 : 23;
        }
        if (wait == WAIT_FAILED) { error(L"wait loader"); CloseHandle(child.hProcess); return 22; }
        if (WaitForSingleObject(target, 0) == WAIT_OBJECT_0) {
            fwprintf(stderr, L"watcher: target exited during loader operation\n"); CloseHandle(child.hProcess); return 24;
        }
        if (GetTickCount64() >= until) {
            fwprintf(stderr, L"watcher: loader wait timed out. No process was terminated.\n"); CloseHandle(child.hProcess); return 25;
        }
    }
}

int wmain(int argc, wchar_t **argv) {
    const wchar_t *image_arg = NULL, *dll_arg = NULL, *loader_arg = NULL, *ready_arg = NULL;
    for (int i = 1; i < argc; ++i) {
        if (i + 1 < argc && !wcscmp(argv[i], L"--image")) image_arg = argv[++i];
        else if (i + 1 < argc && !wcscmp(argv[i], L"--dll")) dll_arg = argv[++i];
        else if (i + 1 < argc && !wcscmp(argv[i], L"--loader")) loader_arg = argv[++i];
        else if (i + 1 < argc && !wcscmp(argv[i], L"--ready-file")) ready_arg = argv[++i];
        else { fwprintf(stderr, L"watcher: unrecognised or incomplete argument\n"); return 2; }
    }
    if (!image_arg || !dll_arg || !loader_arg || !ready_arg) {
        fwprintf(stderr, L"usage: kcdmp_compat_watcher.exe --image FULL_EXE --dll FULL_DLL --loader FULL_LOADER --ready-file FULL_MARKER\n"); return 2;
    }
    if (!absolute(image_arg) || !absolute(dll_arg) || !absolute(loader_arg) || !absolute(ready_arg)) {
        fwprintf(stderr, L"watcher: all paths must be absolute\n"); return 2;
    }
    wchar_t image[PATH_CAP], dll[PATH_CAP], loader[PATH_CAP], ready[PATH_CAP];
    if (!canonical(image_arg, image) || !canonical(dll_arg, dll) || !canonical(loader_arg, loader)) return 3;
    DWORD length = GetFullPathNameW(ready_arg, PATH_CAP, ready, NULL);
    if (!length || length >= PATH_CAP) { error(L"ready path"); return 3; }
    if (!amd64_pe(image, 0) || !amd64_pe(loader, 0) || !amd64_pe(dll, 1)) return 4;
    DWORD pid = 0;
    int found = exact_target(image, &pid);
    if (found < 0) return 5;
    if (found > 0) { fwprintf(stderr, L"watcher: refused existing target process before readiness\n"); return 6; }
    if (!ready_marker(ready)) return 7;
    wprintf(L"watcher: ready. Waiting up to %d ms for a new exact AMD64 target and KcdMp_client.dll\n", WATCH_MS); fflush(stdout);
    ULONGLONG until = GetTickCount64() + WATCH_MS;
    HANDLE target = NULL;
    int result = 8;
    while (GetTickCount64() < until) {
        if (!target) {
            found = exact_target(image, &pid);
            if (found < 0) { result = 5; break; }
            if (found > 1) { fwprintf(stderr, L"watcher: refused multiple matching target processes\n"); result = 9; break; }
            if (found == 1) {
                target = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
                if (!target || !process_path(target, image) || !target_amd64(target)) { error(L"watch target verification"); result = 10; break; }
                wprintf(L"watcher: new exact target pid=%lu\n", pid); fflush(stdout);
            }
        }
        if (target) {
            if (WaitForSingleObject(target, 0) != WAIT_TIMEOUT) { fwprintf(stderr, L"watcher: target exited\n"); result = 11; break; }
            int client = 0, cef = 0;
            if (!modules(pid, &client, &cef)) { result = 12; break; }
            if (cef) { fwprintf(stderr, L"watcher: refused target because libcef.dll is already loaded\n"); result = 13; break; }
            if (client) {
                // This is a best-effort early handoff. The DLL's init must repeat the CEF guard in-process.
                result = start_loader(loader, pid, image, dll, target);
                break;
            }
        }
        Sleep(POLL_MS);
    }
    if (target) CloseHandle(target);
    if (result == 8) fwprintf(stderr, L"watcher: target/client module wait timed out\n");
    DeleteFileW(ready);
    return result;
}
