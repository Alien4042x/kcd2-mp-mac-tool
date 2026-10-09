#pragma once
#include "target-0.40.0.h"
#include <windows.h>
#include <array>
#include <cstring>
namespace compat {
constexpr size_t patch_count = sizeof(target::entries) / sizeof(target::entries[0]);
using PatchBytes = std::array<std::array<unsigned char, 14>, patch_count>;
inline PatchBytes jumps(const std::array<void *, patch_count> &destinations) {
    PatchBytes result = {};
    for (size_t i = 0; i < patch_count; ++i) {
        result[i][0] = 0xff; result[i][1] = 0x25;
        static_assert(sizeof(void *) == 8);
        std::memcpy(result[i].data() + 6, &destinations[i], 8);
    }
    return result;
}
inline DWORD validate_image(unsigned char *base, size_t capacity, const PatchBytes &replacement, bool &already) {
    already = false;
    if (!base || capacity < sizeof(IMAGE_NT_HEADERS64)) return ERROR_BAD_EXE_FORMAT;
    const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 ||
        size_t(dos->e_lfanew) > capacity - sizeof(IMAGE_NT_HEADERS64)) return ERROR_BAD_EXE_FORMAT;
    const auto *pe = reinterpret_cast<const IMAGE_NT_HEADERS64 *>(base + dos->e_lfanew);
    if (pe->Signature != IMAGE_NT_SIGNATURE || pe->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        pe->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        pe->FileHeader.TimeDateStamp != target::timestamp || pe->OptionalHeader.SizeOfImage != target::image_size ||
        pe->OptionalHeader.SizeOfImage > capacity) return ERROR_REVISION_MISMATCH;
    bool all_original = true, all_replaced = true;
    for (const auto &entry : target::read_entries) {
        if (entry.length > sizeof(entry.bytes) || entry.rva > capacity - entry.length) return ERROR_BAD_EXE_FORMAT;
        if (std::memcmp(base + entry.rva, entry.bytes, entry.length) != 0) return ERROR_INVALID_DATA;
    }
    for (size_t i = 0; i < patch_count; ++i) {
        const auto &entry = target::entries[i];
        if (entry.rva > capacity - 14 || entry.end > capacity || entry.end < entry.rva + 14) return ERROR_BAD_EXE_FORMAT;
        all_original &= std::memcmp(base + entry.rva, entry.bytes, 14) == 0;
        all_replaced &= std::memcmp(base + entry.rva, replacement[i].data(), 14) == 0;
    }
    if (!all_original && !all_replaced) return ERROR_INVALID_DATA;
    already = all_replaced;
    return ERROR_SUCCESS;
}
inline bool ip_in_candidate(uintptr_t ip, unsigned char *base) {
    for (const auto &entry : target::entries) {
        if (ip >= uintptr_t(base) + entry.rva && ip < uintptr_t(base) + entry.end) return true;
    }
    return false;
}
}
