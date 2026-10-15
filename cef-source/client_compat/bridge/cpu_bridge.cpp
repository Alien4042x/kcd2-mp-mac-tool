#include "cpu_bridge.h"
#include "shader_bytecode.h"
#include <algorithm>
#include <cstring>
#include <limits>

namespace compat {
namespace {
bool dimensions(int width, int height) {
    return width > 0 && height > 0 && width <= 4096 && height <= 2160;
}
D3D12_HEAP_PROPERTIES heap_properties(D3D12_HEAP_TYPE type) {
    D3D12_HEAP_PROPERTIES result = {};
    result.Type = type;
    result.CreationNodeMask = result.VisibleNodeMask = 1;
    return result;
}
D3D12_RESOURCE_DESC buffer_desc(UINT64 size) {
    D3D12_RESOURCE_DESC result = {};
    result.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    result.Width = size;
    result.Height = result.DepthOrArraySize = result.MipLevels = 1;
    result.SampleDesc.Count = 1;
    result.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    return result;
}
void transition(ID3D12GraphicsCommandList *commands, ID3D12Resource *resource,
    D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    if (before == after) return;
    D3D12_RESOURCE_BARRIER barrier = {};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    commands->ResourceBarrier(1, &barrier);
}

}

bool FrameStore::paint(const void *data, int width, int height, bool popup) noexcept {
    if (!data || !dimensions(width, height)) return false;
    AcquireSRWLockExclusive(&lock_);
    bool okay = false;
    try {
        Pixels &target = popup ? popup_ : view_;
        target.bytes.resize(size_t(width) * height * 4);
        std::memcpy(target.bytes.data(), data, target.bytes.size());
        target.width = width;
        target.height = height;
        target.sequence = ++sequence_;
        okay = true;
    } catch (...) { /* Never propagate a C++ exception into client callbacks. */ }
    ReleaseSRWLockExclusive(&lock_);
    return okay;
}
void FrameStore::popup_rect(int x, int y, int, int) noexcept {
    AcquireSRWLockExclusive(&lock_);
    x_ = x; y_ = y; ++sequence_;
    ReleaseSRWLockExclusive(&lock_);
}
void FrameStore::popup_show(bool shown) noexcept {
    AcquireSRWLockExclusive(&lock_);
    popup_shown_ = shown;
    if (!shown) { popup_.bytes.clear(); popup_.width = popup_.height = 0; }
    ++sequence_;
    ReleaseSRWLockExclusive(&lock_);
}
bool FrameStore::snapshot(Pixels &result) noexcept {
    if (!TryAcquireSRWLockExclusive(&lock_)) return false;
    bool okay = false;
    try {
        if (!view_.bytes.empty()) {
            if (result.sequence != sequence_) {
                result = view_;
                result.sequence = sequence_;
                if (popup_shown_ && !popup_.bytes.empty()) {
                    // Clip all four edges, retain CEF's premultiplied BGRA alpha.
                    for (UINT y = 0; y < popup_.height; ++y) {
                        int64_t dy = int64_t(y_) + y;
                        if (dy < 0 || dy >= result.height) continue;
                        for (UINT x = 0; x < popup_.width; ++x) {
                            int64_t dx = int64_t(x_) + x;
                            if (dx < 0 || dx >= result.width) continue;
                            auto *src = &popup_.bytes[(size_t(y) * popup_.width + x) * 4];
                            auto *dst = &result.bytes[(size_t(dy) * result.width + size_t(dx)) * 4];
                            for (UINT channel = 0; channel < 4; ++channel) {
                                unsigned value = src[channel] + (unsigned(dst[channel]) * (255 - src[3]) + 127) / 255;
                                dst[channel] = static_cast<unsigned char>(std::min(value, 255u));
                            }
                        }
                    }
                }
            }
            okay = true;
        }
    } catch (...) { result.sequence = 0; }
    ReleaseSRWLockExclusive(&lock_);
    return okay;
}
bool FrameStore::size(UINT &width, UINT &height, uint64_t &sequence) noexcept {
    if (!TryAcquireSRWLockShared(&lock_)) return false;
    width = view_.width; height = view_.height; sequence = sequence_;
    bool okay = !view_.bytes.empty();
    ReleaseSRWLockShared(&lock_);
    return okay;
}
void FrameStore::clear() noexcept {
    AcquireSRWLockExclusive(&lock_);
    view_.bytes.clear(); popup_.bytes.clear();
    view_.width = view_.height = popup_.width = popup_.height = 0;
    popup_shown_ = false; ++sequence_;
    ReleaseSRWLockExclusive(&lock_);
}

bool CpuBridge::fail(HRESULT result) noexcept {
    failed_ = true; error_ = result;
    return false;
}
bool CpuBridge::init(ID3D12Device *device, DXGI_FORMAT format) noexcept {
    device_ = device;
    format_ = format;
    HRESULT hr;
    D3D12_DESCRIPTOR_HEAP_DESC heap = {};
    heap.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    heap.NumDescriptors = UINT(slots_.size());
    heap.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    if (FAILED(hr = device->CreateDescriptorHeap(&heap, IID_PPV_ARGS(&heap_)))) return fail(hr);
    descriptor_size_ = device->GetDescriptorHandleIncrementSize(heap.Type);
    if (FAILED(hr = device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence_)))) return fail(hr);

    D3D12_DESCRIPTOR_RANGE range = {};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    range.NumDescriptors = 1;
    D3D12_ROOT_PARAMETER parameter = {};
    parameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameter.DescriptorTable.NumDescriptorRanges = 1;
    parameter.DescriptorTable.pDescriptorRanges = &range;
    parameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_STATIC_SAMPLER_DESC sampler = {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxAnisotropy = 1;
    sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC root_desc = {};
    root_desc.NumParameters = 1; root_desc.pParameters = &parameter;
    root_desc.NumStaticSamplers = 1; root_desc.pStaticSamplers = &sampler;
    root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ComPtr<ID3DBlob> serialized, errors;
    if (FAILED(hr = D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &serialized, &errors))) return fail(hr);
    if (FAILED(hr = device->CreateRootSignature(0, serialized->GetBufferPointer(), serialized->GetBufferSize(), IID_PPV_ARGS(&root_)))) return fail(hr);
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline = {};
    pipeline.pRootSignature = root_.Get();
    pipeline.VS = {shader_vs, sizeof(shader_vs)};
    pipeline.PS = {shader_ps, sizeof(shader_ps)};
    auto &blend = pipeline.BlendState.RenderTarget[0];
    blend.BlendEnable = TRUE;
    blend.SrcBlend = blend.SrcBlendAlpha = D3D12_BLEND_ONE;
    blend.DestBlend = blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
    blend.BlendOp = blend.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    blend.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pipeline.SampleMask = UINT_MAX;
    pipeline.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pipeline.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pipeline.RasterizerState.DepthClipEnable = TRUE;
    pipeline.DepthStencilState.DepthEnable = FALSE;
    pipeline.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
    pipeline.DepthStencilState.StencilEnable = FALSE;
    pipeline.DepthStencilState.StencilReadMask = D3D12_DEFAULT_STENCIL_READ_MASK;
    pipeline.DepthStencilState.StencilWriteMask = D3D12_DEFAULT_STENCIL_WRITE_MASK;
    pipeline.DepthStencilState.FrontFace = {D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_COMPARISON_FUNC_ALWAYS};
    pipeline.DepthStencilState.BackFace = pipeline.DepthStencilState.FrontFace;
    pipeline.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    pipeline.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pipeline.NumRenderTargets = 1;
    pipeline.RTVFormats[0] = format;
    pipeline.SampleDesc.Count = 1;
    if (FAILED(hr = device->CreateGraphicsPipelineState(&pipeline, IID_PPV_ARGS(&pipeline_)))) return fail(hr);
    return true;
}
bool CpuBridge::resize(Slot &slot, UINT index, UINT width, UINT height) noexcept {
    if (slot.mapped) { slot.upload->Unmap(0, nullptr); slot.mapped = nullptr; }
    slot.texture.Reset(); slot.upload.Reset(); slot.pixels = 0;
    D3D12_RESOURCE_DESC texture = {};
    texture.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    texture.Width = width; texture.Height = height;
    texture.DepthOrArraySize = texture.MipLevels = 1;
    texture.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    texture.SampleDesc.Count = 1;
    UINT64 size = 0;
    device_->GetCopyableFootprints(&texture, 0, 1, 0, &slot.footprint, nullptr, nullptr, &size);
    if (!size) return fail(E_FAIL);
    auto defaults = heap_properties(D3D12_HEAP_TYPE_DEFAULT);
    auto uploads = heap_properties(D3D12_HEAP_TYPE_UPLOAD);
    auto buffer = buffer_desc(size);
    HRESULT hr;
    if (FAILED(hr = device_->CreateCommittedResource(&defaults, D3D12_HEAP_FLAG_NONE, &texture,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&slot.texture)))) return fail(hr);
    if (FAILED(hr = device_->CreateCommittedResource(&uploads, D3D12_HEAP_FLAG_NONE, &buffer,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&slot.upload)))) return fail(hr);
    D3D12_RANGE empty = {};
    if (FAILED(hr = slot.upload->Map(0, &empty, reinterpret_cast<void **>(&slot.mapped)))) return fail(hr);
    auto cpu = heap_->GetCPUDescriptorHandleForHeapStart();
    cpu.ptr += size_t(index) * descriptor_size_;
    D3D12_SHADER_RESOURCE_VIEW_DESC srv = {};
    srv.Format = texture.Format;
    srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    srv.Texture2D.MipLevels = 1;
    device_->CreateShaderResourceView(slot.texture.Get(), &srv, cpu);
    slot.width = width; slot.height = height;
    slot.state = D3D12_RESOURCE_STATE_COPY_DEST;
    return true;
}
bool CpuBridge::record(FrameStore &frames, ID3D12Device *device, DXGI_FORMAT format,
    ID3D12GraphicsCommandList *commands, UINT width, UINT height) noexcept {
    if (failed_ || !device || !commands || !width || !height) return false;
    if (pending_ >= 0) return fail(E_UNEXPECTED); // Missing submit callback.
    if (!frames.snapshot(pixels_) && pixels_.bytes.empty()) return false;
    if (device_ && (device_.Get() != device || format_ != format)) {
        if (!idle()) return false;
        reset_after_gpu_idle();
    }
    if (!device_ && !init(device, format)) return false;
    UINT64 completed = fence_->GetCompletedValue();
    if (completed == UINT64_MAX) return fail(DXGI_ERROR_DEVICE_REMOVED);
    int index = -1;
    for (UINT i = 0; i < slots_.size(); ++i) {
        if (slots_[i].retired <= completed) { index = int(i); break; }
    }
    if (index < 0) return false; // Bounded ring, skip a frame instead of waiting.
    Slot &slot = slots_[index];
    if (slot.width != pixels_.width || slot.height != pixels_.height) {
        if (!resize(slot, UINT(index), pixels_.width, pixels_.height)) return false;
    }
    if (slot.pixels != pixels_.sequence) {
        for (UINT y = 0; y < pixels_.height; ++y) {
            std::memcpy(slot.mapped + slot.footprint.Offset + size_t(y) * slot.footprint.Footprint.RowPitch,
                &pixels_.bytes[size_t(y) * pixels_.width * 4], size_t(pixels_.width) * 4);
        }
        transition(commands, slot.texture.Get(), slot.state, D3D12_RESOURCE_STATE_COPY_DEST);
        D3D12_TEXTURE_COPY_LOCATION source = {}, destination = {};
        source.pResource = slot.upload.Get(); source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        source.PlacedFootprint = slot.footprint;
        destination.pResource = slot.texture.Get(); destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        commands->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
        transition(commands, slot.texture.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        slot.state = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
        slot.pixels = pixels_.sequence;
    }
    ID3D12DescriptorHeap *heaps[] = {heap_.Get()};
    commands->SetDescriptorHeaps(1, heaps);
    commands->SetGraphicsRootSignature(root_.Get());
    commands->SetPipelineState(pipeline_.Get());
    auto gpu = heap_->GetGPUDescriptorHandleForHeapStart();
    gpu.ptr += UINT64(index) * descriptor_size_;
    commands->SetGraphicsRootDescriptorTable(0, gpu);
    D3D12_VIEWPORT viewport = {0, 0, float(width), float(height), 0, 1};
    D3D12_RECT scissor = {0, 0, LONG(width), LONG(height)};
    commands->RSSetViewports(1, &viewport);
    commands->RSSetScissorRects(1, &scissor);
    commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    commands->DrawInstanced(3, 1, 0, 0);
    slot.retired = UINT64_MAX;
    pending_ = index;
    return true;
}
bool CpuBridge::submitted(ID3D12CommandQueue *queue) noexcept {
    if (pending_ < 0) return !failed_;
    if (!queue || !fence_) return fail(E_POINTER);
    UINT64 value = ++sequence_;
    HRESULT hr = queue->Signal(fence_.Get(), value);
    if (FAILED(hr)) return fail(hr);
    slots_[pending_].retired = value;
    pending_ = -1;
    return true;
}
bool CpuBridge::idle() const noexcept {
    if (pending_ >= 0) return false;
    if (!fence_) return true;
    auto completed = fence_->GetCompletedValue();
    for (const auto &slot : slots_) if (slot.retired > completed) return false;
    return true;
}
void CpuBridge::reset_after_gpu_idle() noexcept {
    for (auto &slot : slots_) {
        if (slot.mapped) slot.upload->Unmap(0, nullptr);
        slot = Slot{};
    }
    pipeline_.Reset(); root_.Reset(); fence_.Reset(); heap_.Reset(); device_.Reset();
    format_ = DXGI_FORMAT_UNKNOWN; descriptor_size_ = 0;
    sequence_ = 0; pending_ = -1; failed_ = false; error_ = S_OK;
}
}
