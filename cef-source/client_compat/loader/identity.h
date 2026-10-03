#pragma once
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0a00
#endif
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdint.h>
#include <wchar.h>
#include <string.h>
#define PATH_CAP 32768

static inline void error(const wchar_t *step) {
    DWORD code = GetLastError();
    wchar_t text[512] = L"";
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL, code, 0, text, 512, NULL);
    for (wchar_t *p = text; *p; ++p) if (*p == L'\r' || *p == L'\n') *p = L' ';
    fwprintf(stderr, L"loader: %ls failed, error=%lu (0x%08lx) %ls\n", step, code, code, text);
}

/* Open an existing file and canonicalise its full path. Never compare only a basename. */
static inline int canonical(const wchar_t *input, wchar_t *output) {
    HANDLE file = CreateFileW(input, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) { error(L"open path"); return 0; }
    DWORD size = GetFinalPathNameByHandleW(file, output, PATH_CAP, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(file);
    if (!size || size >= PATH_CAP) { error(L"canonical path"); return 0; }
    if (wcsncmp(output, L"\\\\?\\UNC\\", 8) == 0) {
        memmove(output + 2, output + 8, (wcslen(output + 8) + 1) * sizeof(wchar_t));
        output[0] = output[1] = L'\\';
    } else if (wcsncmp(output, L"\\\\?\\", 4) == 0) {
        memmove(output, output + 4, (wcslen(output + 4) + 1) * sizeof(wchar_t));
    }
    return 1;
}

static inline int same_path(const wchar_t *a, const wchar_t *b) {
    return CompareStringOrdinal(a, -1, b, -1, TRUE) == CSTR_EQUAL;
}

static inline int read_at(HANDLE file, LONGLONG offset, void *data, DWORD size) {
    LARGE_INTEGER where; where.QuadPart = offset;
    DWORD read = 0;
    return SetFilePointerEx(file, where, NULL, FILE_BEGIN) &&
        ReadFile(file, data, size, &read, NULL) && read == size;
}

static inline int amd64_pe(const wchar_t *path, int dll) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) { error(L"open PE image"); return 0; }
    IMAGE_DOS_HEADER dos; DWORD signature; IMAGE_FILE_HEADER header; WORD magic;
    LARGE_INTEGER bytes;
    int ok = GetFileSizeEx(file, &bytes) && bytes.QuadPart >= (LONGLONG)sizeof(dos) &&
        read_at(file, 0, &dos, sizeof(dos)) && dos.e_magic == IMAGE_DOS_SIGNATURE &&
        dos.e_lfanew >= (LONG)sizeof(dos) &&
        (LONGLONG)dos.e_lfanew + 4 + (LONGLONG)sizeof(header) + 2 <= bytes.QuadPart &&
        read_at(file, dos.e_lfanew, &signature, sizeof(signature)) && signature == IMAGE_NT_SIGNATURE &&
        read_at(file, dos.e_lfanew + 4, &header, sizeof(header)) &&
        header.Machine == IMAGE_FILE_MACHINE_AMD64 &&
        header.SizeOfOptionalHeader >= sizeof(IMAGE_OPTIONAL_HEADER64) &&
        (LONGLONG)dos.e_lfanew + 4 + (LONGLONG)sizeof(header) + header.SizeOfOptionalHeader <= bytes.QuadPart &&
        read_at(file, dos.e_lfanew + 4 + sizeof(header), &magic, sizeof(magic)) &&
        magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC &&
        ((header.Characteristics & IMAGE_FILE_DLL) != 0) == dll;
    CloseHandle(file);
    if (!ok) fwprintf(stderr, L"loader: refused non-AMD64 or invalid %ls PE image: %ls\n", dll ? L"DLL" : L"EXE", path);
    return ok;
}

static inline int target_amd64(HANDLE process) {
    typedef BOOL (WINAPI *Wow64Process2)(HANDLE, USHORT *, USHORT *);
    Wow64Process2 wow2 = (Wow64Process2)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2");
    if (wow2) {
        USHORT machine = 0, native = 0;
        if (!wow2(process, &machine, &native)) { error(L"IsWow64Process2"); return 0; }
        if (machine == IMAGE_FILE_MACHINE_UNKNOWN && native == IMAGE_FILE_MACHINE_AMD64) return 1;
        fwprintf(stderr, L"loader: refused target architecture process=0x%04x native=0x%04x\n", machine, native);
        return 0;
    }
    BOOL wow = FALSE; SYSTEM_INFO system;
    if (!IsWow64Process(process, &wow)) { error(L"IsWow64Process"); return 0; }
    GetNativeSystemInfo(&system);
    if (!wow && system.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64) return 1;
    fwprintf(stderr, L"loader: refused target architecture\n");
    return 0;
}

static inline int process_path(HANDLE process, const wchar_t *expected) {
    wchar_t actual[PATH_CAP], normal[PATH_CAP]; DWORD size = PATH_CAP;
    if (!QueryFullProcessImageNameW(process, 0, actual, &size)) { error(L"QueryFullProcessImageNameW"); return 0; }
    if (!canonical(actual, normal)) return 0;
    if (!same_path(expected, normal)) {
        fwprintf(stderr, L"loader: refused process image mismatch\n  expected: %ls\n  actual:   %ls\n", expected, normal);
        return 0;
    }
    return 1;
}
