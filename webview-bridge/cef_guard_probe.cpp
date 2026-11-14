#include "patch_guard.h"
#include <vector>
#include <cstdio>

static int failed(const char *message) { std::fprintf(stderr,"CEF_GUARD_FAIL %s\n",message);return 1; }
int main() {
    std::vector<unsigned char> image(target::image_size);
    auto *dos=reinterpret_cast<IMAGE_DOS_HEADER *>(image.data());
    dos->e_magic=IMAGE_DOS_SIGNATURE;dos->e_lfanew=0x80;
    auto *pe=reinterpret_cast<IMAGE_NT_HEADERS64 *>(image.data()+dos->e_lfanew);
    pe->Signature=IMAGE_NT_SIGNATURE;
    pe->FileHeader.Machine=IMAGE_FILE_MACHINE_AMD64;
    pe->FileHeader.TimeDateStamp=target::timestamp;
    pe->OptionalHeader.Magic=IMAGE_NT_OPTIONAL_HDR64_MAGIC;
    pe->OptionalHeader.SizeOfImage=target::image_size;
    for(const auto &entry:target::read_entries)std::memcpy(image.data()+entry.rva,entry.bytes,entry.length);
    for(const auto &entry:target::entries)std::memcpy(image.data()+entry.rva,entry.bytes,14);
    std::array<void *,compat::patch_count> destinations{};
    for(size_t i=0;i<destinations.size();++i)destinations[i]=reinterpret_cast<void *>(0x1000+i*0x100);
    auto patches=compat::jumps(destinations);bool already=false;
    if(compat::validate_image(image.data(),image.size(),patches,already)||already)return failed("valid original image");
    pe->FileHeader.Machine=IMAGE_FILE_MACHINE_I386;
    if(compat::validate_image(image.data(),image.size(),patches,already)==0)return failed("wrong architecture accepted");
    pe->FileHeader.Machine=IMAGE_FILE_MACHINE_AMD64;
    image[target::entries[0].rva]^=1;
    if(compat::validate_image(image.data(),image.size(),patches,already)==0)return failed("changed signature accepted");
    image[target::entries[0].rva]^=1;
    for(size_t i=0;i<compat::patch_count;++i)std::memcpy(image.data()+target::entries[i].rva,patches[i].data(),14);
    if(compat::validate_image(image.data(),image.size(),patches,already)||!already)return failed("already-patched image");
    std::memcpy(image.data()+target::entries[0].rva,target::entries[0].bytes,14);
    if(compat::validate_image(image.data(),image.size(),patches,already)==0)return failed("mixed partial image accepted");
    if(compat::validate_image(image.data(),16,patches,already)==0)return failed("truncated image accepted");
    HMODULE helper=LoadLibraryW(L"KcdMpCefCompat-0.50.0.dll");
    if(!helper)return failed("helper load");
    using Initialize=DWORD (WINAPI *)(void *);
    auto initialize=reinterpret_cast<Initialize>(GetProcAddress(helper,"KcdMpCefCompatInitialize"));
    DWORD status=initialize?initialize(nullptr):ERROR_PROC_NOT_FOUND;
    FreeLibrary(helper);
    if(status!=ERROR_ACCESS_DENIED)return failed("wrong process was not refused");
    std::puts("CEF_GUARD_PASS architecture, changed signature, already-patched, partial image, bounds and wrong process");
    return 0;
}
