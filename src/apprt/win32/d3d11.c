// Minimal D3D11 presenter for the Win32 app runtime.
//
// The renderer produces CPU frames (BGRA, top-down), so all this layer has
// to do is get them onto the screen with a swap chain instead of GDI. It
// lives in C because the D3D11 COM interfaces are painful to model by hand
// in Zig, and because a handful of plain functions is all the runtime
// needs.
//
// Every entry point is best-effort: `create` returns NULL when D3D11 is
// unavailable (no GPU, old driver, remote session), and the caller falls
// back to GDI. `present` returns 0 on failure so the caller can fall back
// too, for example after a device-removed error.

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdlib.h>
#include <string.h>

// The SDK exposes the interface IIDs through uuid.lib, which the build
// does not link. Defining the one GUID we need locally is simpler.
static const GUID IID_ghostty_D3D11Texture2D =
    {0x6f15aaf2, 0xd208, 0x4e89, {0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c}};

typedef struct {
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain *swap;
    int width;
    int height;
} ghostty_d3d11;

static int ghostty_d3d11_resize(ghostty_d3d11 *p, int width, int height) {
    if (p->width == width && p->height == height) return 1;

    // Buffer 0 is the only one we write to; passing 0 keeps the rest.
    if (FAILED(p->swap->lpVtbl->ResizeBuffers(
            p->swap, 0, (UINT)width, (UINT)height, DXGI_FORMAT_UNKNOWN, 0))) {
        return 0;
    }

    p->width = width;
    p->height = height;
    return 1;
}

void *ghostty_d3d11_create(HWND hwnd, int width, int height) {
    if (width <= 0 || height <= 0) return NULL;

    DXGI_SWAP_CHAIN_DESC desc;
    memset(&desc, 0, sizeof(desc));
    desc.BufferCount = 2;
    desc.BufferDesc.Width = (UINT)width;
    desc.BufferDesc.Height = (UINT)height;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.BufferDesc.RefreshRate.Numerator = 0;
    desc.BufferDesc.RefreshRate.Denominator = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.OutputWindow = hwnd;
    desc.SampleDesc.Count = 1;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
    };
    D3D_FEATURE_LEVEL got;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGISwapChain *swap = NULL;

    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        NULL,
        D3D_DRIVER_TYPE_HARDWARE,
        NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        levels,
        (UINT)(sizeof(levels) / sizeof(levels[0])),
        D3D11_SDK_VERSION,
        &desc,
        &swap,
        &device,
        &got,
        &context);
    if (FAILED(hr)) return NULL;

    ghostty_d3d11 *p = (ghostty_d3d11 *)calloc(1, sizeof(ghostty_d3d11));
    if (p == NULL) {
        swap->lpVtbl->Release(swap);
        context->lpVtbl->Release(context);
        device->lpVtbl->Release(device);
        return NULL;
    }

    p->device = device;
    p->context = context;
    p->swap = swap;
    p->width = width;
    p->height = height;
    return p;
}

// Upload `bgra` (tightly packed, top-down, `width * 4` bytes per row) into
// the back buffer and present it with vsync.
int ghostty_d3d11_present(void *opaque, const void *bgra, int width, int height) {
    ghostty_d3d11 *p = (ghostty_d3d11 *)opaque;
    if (p == NULL) return 0;
    if (width <= 0 || height <= 0) return 0;
    if (!ghostty_d3d11_resize(p, width, height)) return 0;

    ID3D11Texture2D *back = NULL;
    if (FAILED(p->swap->lpVtbl->GetBuffer(
            p->swap, 0, &IID_ghostty_D3D11Texture2D, (void **)&back))) {
        return 0;
    }

    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(p->context->lpVtbl->Map(
            p->context,
            (ID3D11Resource *)back,
            0,
            D3D11_MAP_WRITE_DISCARD,
            0,
            &mapped))) {
        back->lpVtbl->Release(back);
        return 0;
    }

    const unsigned char *src = (const unsigned char *)bgra;
    unsigned char *dst = (unsigned char *)mapped.pData;
    const size_t row = (size_t)width * 4;
    for (int y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * mapped.RowPitch, src + (size_t)y * row, row);
    }

    p->context->lpVtbl->Unmap(p->context, (ID3D11Resource *)back, 0);
    back->lpVtbl->Release(back);

    return SUCCEEDED(p->swap->lpVtbl->Present(p->swap, 1, 0));
}

void ghostty_d3d11_destroy(void *opaque) {
    ghostty_d3d11 *p = (ghostty_d3d11 *)opaque;
    if (p == NULL) return;

    if (p->swap != NULL) p->swap->lpVtbl->Release(p->swap);
    if (p->context != NULL) p->context->lpVtbl->Release(p->context);
    if (p->device != NULL) p->device->lpVtbl->Release(p->device);
    free(p);
}
