#pragma once
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>
#include <array>
#include <cstdint>
#include <vector>

namespace compat {
using Microsoft::WRL::ComPtr;
struct Pixels {
    std::vector<unsigned char> bytes;
    UINT width = 0, height = 0;
    uint64_t sequence = 0;
};
// CEF owns the incoming buffer. Copy it during OnPaint, never retain its pointer.
class FrameStore {
    SRWLOCK lock_ = SRWLOCK_INIT;
    Pixels view_, popup_;
    int x_ = 0, y_ = 0;
    bool popup_shown_ = false;
    uint64_t sequence_ = 0;
public:
    bool paint(const void *data, int width, int height, bool popup) noexcept;
    void popup_rect(int x, int y, int width, int height) noexcept;
    void popup_show(bool shown) noexcept;
    bool snapshot(Pixels &result) noexcept;
    bool size(UINT &width, UINT &height, uint64_t &sequence) noexcept;
    void clear() noexcept;
};
// Render-thread-only, three slots. Never wait for the GPU on the render thread.
class CpuBridge {
    struct Slot {
        ComPtr<ID3D12Resource> texture, upload;
        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = {};
        unsigned char *mapped = nullptr;
        UINT width = 0, height = 0;
        uint64_t retired = 0, pixels = 0;
        D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COPY_DEST;
    };
    std::array<Slot, 3> slots_;
    ComPtr<ID3D12Device> device_;
    ComPtr<ID3D12DescriptorHeap> heap_;
    ComPtr<ID3D12Fence> fence_;
    ComPtr<ID3D12RootSignature> root_;
    ComPtr<ID3D12PipelineState> pipeline_;
    DXGI_FORMAT format_ = DXGI_FORMAT_UNKNOWN;
    UINT descriptor_size_ = 0;
    uint64_t sequence_ = 0;
    int pending_ = -1;
    bool failed_ = false;
    HRESULT error_ = S_OK;
    Pixels pixels_;
    bool fail(HRESULT result) noexcept;
    bool init(ID3D12Device *device, DXGI_FORMAT format) noexcept;
    bool resize(Slot &slot, UINT index, UINT width, UINT height) noexcept;
public:
    bool record(FrameStore &frames, ID3D12Device *device, DXGI_FORMAT format,
        ID3D12GraphicsCommandList *commands, UINT width, UINT height) noexcept;
    bool submitted(ID3D12CommandQueue *queue) noexcept;
    // Client calls this callback after its own wait_for_gpu, before heap teardown.
    void reset_after_gpu_idle() noexcept;
    bool idle() const noexcept;
    bool failed() const noexcept { return failed_; }
    HRESULT error() const noexcept { return error_; }
};
}
