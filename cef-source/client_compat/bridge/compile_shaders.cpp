#include "page_shader_source.h"
#include <windows.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <cstdio>
#include <initializer_list>
using Microsoft::WRL::ComPtr;
int wmain(int argc, wchar_t **argv) {
    if (argc != 2) return 2;
    FILE *output = _wfopen(argv[1], L"wb"); if (!output) return 3;
    std::fprintf(output, "// DXBC compiled from page_shader_source.h, no runtime shader compilation.\n#pragma once\n");
    for (auto name : {"vs", "ps"}) {
        char entry[32], profile[32]; std::snprintf(entry, sizeof(entry), "%s_main", name); std::snprintf(profile, sizeof(profile), "%s_5_0", name);
        ComPtr<ID3DBlob> blob, errors;
        HRESULT hr = D3DCompile(page_shader_source, sizeof(page_shader_source)-1, "kcdmp-cef-compat", nullptr, nullptr,
            entry, profile, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &blob, &errors);
        if (FAILED(hr)) { std::fclose(output); return 4; }
        std::fprintf(output, "constexpr unsigned char shader_%s[] = {\n", name);
        auto *data = static_cast<const unsigned char *>(blob->GetBufferPointer());
        for (size_t i = 0; i < blob->GetBufferSize(); ++i) std::fprintf(output, "%s0x%02x,%s", i%16==0?"    ":"", data[i], i%16==15?"\n":" ");
        std::fprintf(output, "\n};\n");
    }
    std::fclose(output); std::printf("SHADERS|PASS|embedded DXBC\n"); return 0;
}
