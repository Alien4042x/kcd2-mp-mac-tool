/* Exercise the real watcher's module reader with controlled Win32 failures.
 * This program never opens or injects another process. */
#include "identity.h"
#include <assert.h>
static DWORD probe_error;
static int probe_case, probe_index, snapshots;
static ULONGLONG probe_now = 100;
static HANDLE probe_snapshot(DWORD flags, DWORD pid) {
    assert(flags == (TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32) && pid == 42);
    ++snapshots;
    if (probe_error) { SetLastError(probe_error); return INVALID_HANDLE_VALUE; }
    return (HANDLE)(uintptr_t)77;
}
static BOOL probe_first(HANDLE handle, LPMODULEENTRY32W entry) {
    assert(handle == (HANDLE)(uintptr_t)77);
    probe_index = 0;
    if (probe_case == 3) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
    wcscpy(entry->szModule, L"KcdMp_client.dll"); return TRUE;
}
static BOOL probe_next(HANDLE handle, LPMODULEENTRY32W entry) {
    assert(handle == (HANDLE)(uintptr_t)77);
    if (probe_case == 1 && probe_index++ == 0) { wcscpy(entry->szModule, L"libcef.dll"); return TRUE; }
    SetLastError(probe_case == 2 ? ERROR_ACCESS_DENIED : ERROR_NO_MORE_FILES); return FALSE;
}
static BOOL probe_close(HANDLE handle) { assert(handle == (HANDLE)(uintptr_t)77); return TRUE; }
static void probe_sleep(DWORD ms) { probe_now += ms; }
static ULONGLONG probe_tick(void) { return probe_now; }
#define CreateToolhelp32Snapshot probe_snapshot
#define Module32FirstW probe_first
#define Module32NextW probe_next
#define CloseHandle probe_close
#define Sleep probe_sleep
#define GetTickCount64 probe_tick
#define wmain unused_watcher_main
#include "watcher.c"
#undef wmain
int wmain(void) {
    int client, cef;
    probe_error = ERROR_ACCESS_DENIED;
    assert(modules(42, &client, &cef, 2100) == 2 && !client && !cef);
    probe_error = 0;
    assert(modules(42, &client, &cef, 2100) == 1 && client && !cef);
    probe_case = 1;
    assert(modules(42, &client, &cef, 2100) == 1 && client && cef);
    probe_case = 2;
    assert(modules(42, &client, &cef, 2100) == 2 && !client && !cef);
    probe_case = 3;
    assert(modules(42, &client, &cef, 2100) == 2 && !client && !cef);
    probe_now = 2100;
    assert(modules(42, &client, &cef, 2100) == 0 && !client && !cef);
    probe_error = ERROR_ACCESS_DENIED;
    assert(modules(42, &client, &cef, 2100) == 0 && !client && !cef);
    probe_error = ERROR_INVALID_HANDLE;
    assert(modules(42, &client, &cef, 3000) == 0 && !client && !cef);
    probe_error = ERROR_PARTIAL_COPY;
    assert(modules(42, &client, &cef, 3000) == 2 && !client && !cef);
    probe_error = ERROR_BAD_LENGTH;
    assert(modules(42, &client, &cef, 3000) == 2 && !client && !cef);
    assert(snapshots > 10);
    puts("PASS real watcher module reader: denied startup then readable, CEF detection, partial enumeration, grace boundary, persistent denial and other errors");
    return 0;
}
