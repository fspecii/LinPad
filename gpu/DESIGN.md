# GPU acceleration for iSH-ARM64: Venus over an emulated virtio-gpu render node

Status: round 2 (2026-10-02): GPU on by default in the iOS app (device + simulator builds), reproducible third-party and rootfs scripts, per-client EGL opt-in in ishwl. Firefox: software raster + GL compositor works on the GPU; full GPU WebRender does not yet. Results: /Volumes/ExternalHD/Dev/ipad-jit/gpu-report.md

## Pipeline

```
guest app (Vulkan)            guest app (GL/GLES)
   |                              |  Mesa zink (GL on Vulkan), MESA_LOADER_DRIVER_OVERRIDE=zink
   v                              v
guest libvulkan_virtio.so (Mesa Venus ICD)
   |  ioctl/mmap on /dev/dri/renderD128   (virtgpu uAPI)
   v
iSH: fs/dev_virtgpu.c  (emulated virtio-gpu DRM device, in the emulator process)
   |  direct C calls, no VM exit
   v
virglrenderer (venus, render server in a thread of the same process)
   |
   v
MoltenVK -> Metal -> Apple GPU
```

## M0 findings

### Guest side (Alpine 3.21 aarch64)

* Alpine 3.21 does **not** ship the Venus ICD (`apk search mesa-vulkan` has ati, broadcom,
  freedreno, panfrost, swrast, layers; no `virtio`). Neither do 3.22 or 3.23. Only **edge**
  has `mesa-vulkan-virtio` (26.2.3).
* The edge package works on 3.21 when extracted by hand (not `apk add`, it pins `mesa=26.2.3`)
  together with three newer, ABI-compatible libraries from edge:
  `libdisplay-info` 0.3 (`.so.3`, installed side by side with the 3.21 `.so.2`),
  `libxcb` 1.17 (xcb_dri3 syncobj symbols) and `wayland-libs-client` 1.26 (`wl_fixes_interface`,
  `wl_display_dispatch_queue_timeout`). musl has no symbol versioning, so `ldd` is the test:
  it is clean afterwards. Packages are kept in `gpu/pkgs/`.
* Zink is in 3.21's `mesa-dri-gallium` 24.2.8 (`/usr/lib/xorg/modules/dri/zink_dri.so`,
  inside `libgallium-24.2.8.so`). It is independent of the ICD version (it talks to whatever
  Vulkan driver the loader gives it).
* `vulkan-tools` 1.3.296 (vulkaninfo, vkcube) and `mesa-vulkan-swrast` (lavapipe, CPU baseline)
  are in 3.21.

### What Venus needs from the kernel (Mesa 26.2 `vn_renderer_virtgpu.c`)

* Device discovery through libdrm `drmGetDevices2`: a char node `/dev/dri/renderD128` (226:128),
  and sysfs: `/sys/dev/char/226:128/device/{drm/,subsystem->.../platform,uevent}`.
  `drmGetVersion` must report driver name `virtio_gpu`, major 0. Platform bus is accepted by Venus.
* GETPARAM: 3D_FEATURES, CAPSET_QUERY_FIX, RESOURCE_BLOB, CONTEXT_INIT (required), HOST_VISIBLE
  (selects BLOB_MEM_HOST3D), CROSS_DEVICE (optional, 0).
* GET_CAPS capset 4 (VENUS) v0; CONTEXT_INIT with CAPSET_ID=4, NUM_RINGS=64, POLL_RINGS_MASK=0.
* RESOURCE_CREATE_BLOB (HOST3D, with an embedded command for vkAllocateMemory, or blob_id 0 for
  shmem), RESOURCE_INFO, MAP + `mmap(fd, offset)`, GEM_CLOSE, EXECBUFFER with RING_IDX.
* Sync: if `DRM_CAP_SYNCOBJ_TIMELINE` is absent, Venus uses its simulated syncobjs, which only
  need `EXECBUFFER(FENCE_FD_OUT)` to return a pollable fd that turns POLLIN when the ring fence
  retires. No DRM syncobj ioctls are needed.
* PRIME_HANDLE_TO_FD / FD_TO_HANDLE only for exported/imported external memory (dma-buf WSI).

### Host side

* Upstream virglrenderer (main, aafa9bd2) already has macOS Venus support: host-visible memory is
  an anonymous shm file mapped and wrapped as `MTLBuffer` (`newBufferWithBytesNoCopy`) and
  imported into MoltenVK with `VK_EXT_external_memory_metal`; the blob is exported as an
  `FD_SHM`. That is exactly what iSH needs: the guest mapping is a second host `mmap` of the
  same shm fd, so guest writes and MoltenVK/Metal reads hit the same physical pages.
* Build (no patches needed on macOS):
  `meson setup build-macos -Dvenus=true -Dvrend=false -Drender-server-mode=thread
  -Drender-server-worker=thread -Ddefault_library=static -Dunstable-apis=true`.
  `render-server-mode=thread` puts the render server in a thread of the caller (no fork/exec,
  which iOS forbids). Dependencies: Homebrew molten-vk 1.4.1, vulkan-loader/headers, python mako.
* `gpu/tests/host_smoke.c`: `virgl_renderer_init(VENUS|NO_VIRGL|RENDER_SERVER|THREAD_SYNC|
  ASYNC_FENCE_CB)` succeeds, the venus capset is 160 bytes (wire format 1, vk.xml 1.4.165),
  a venus context is created on MoltenVK.

### Go / no-go: GO

## Design of the emulated device (`fs/dev_virtgpu.c`)

* Built only with `-Dvirtgpu=enabled` (`ISH_VIRTGPU`). Hooks: char major 226 in `fs/dev.c`,
  node + sysfs creation at boot, meson dependency. Default builds are unchanged.
* One open file = one DRM file = one virgl context (`ctx_id` global counter). GEM handle ->
  bo `{res_id, size, blob_mem, flags}` per file.
* All `virgl_renderer_*` calls are serialized by one global mutex (the library is not
  thread-safe). The fence callback runs on virglrenderer's sync thread and only touches
  per-context fence state + `poll_wakeup`, never the global mutex.
* Guest memory: ioctl structs are copied by iSH's ioctl layer (`_IOC_SIZE`); nested pointers
  (execbuffer commands, caps buffer, ctx params, drm_version strings) use `user_read`/`user_write`.
* Fences: macOS/iOS have no eventfd, so virglrenderer cannot signal fences from its own
  thread (`THREAD_SYNC`/`ASYNC_FENCE_CB` need eventfd). A `virtgpu-fence` thread calls
  `virgl_renderer_context_poll` every 200 us, only while some ring has an unsignaled fence.
* `mmap`: VIRTGPU_MAP returns `offset = handle << 12`; the fd's mmap op exports the blob fd
  (`virgl_renderer_resource_export_blob`, SHM), host-`mmap`s it `MAP_SHARED`, and hands the
  pointer to `pt_map`, which owns and later munmaps it. Zero copy; the emulator's page table
  points straight at the Metal-visible pages.
* Fence fds: an adhoc fd that holds a ref on the context and its `(ring, fence_id)`; `poll`
  reports POLLIN once `signaled[ring] >= fence_id`.

## Things that had to change outside fs/dev_virtgpu.c

* **MoltenVK >= 1.4.2.** 1.4.1 ignores the imported MTLBuffer's residency, so GPU writes
  never reach the shm pages (compute and readback return zeros). Fixed upstream by
  "Make imported MTLBuffer resident in MVKDeviceMemory" (v1.4.2). Host test:
  `gpu/tests/mvk_import.m`.
* **virglrenderer patch** `gpu/patches/virglrenderer-ish.patch`:
  - `VKR_ZINK_COMPAT=1` (set by iSH): advertise robustness2.nullDescriptor (MoltenVK issue
    2650; zink >= 25.3 requires it) and VK_EXT_external_memory_dma_buf (venus only exposes
    VK_KHR_external_memory_fd, which zink's DRM screen requires, when the renderer has it);
    both are stripped again before vkCreateDevice reaches MoltenVK.
  - iOS: `os_create_anonymous_file` falls back to an unlinked file in `$TMPDIR` when
    `shm_open` is refused by the sandbox.
* **Guest Mesa from edge** (26.2.3 when this was written; the image pins whatever
  `rootfs-add-gpu.sh` names): venus ICD + zink/EGL/GBM/GLES. 3.21's zink 24.2.8 dies
  silently in `zink_drm_create_screen` for the same KHR_external_memory_fd reason.
* **mincore** (kernel/fs.c): returned success for unmapped pages. Mesa EGL's
  `_eglPointerIsDereferenceable` then took `wl_egl_window->version` (3) for a wl_surface
  pointer and every EGL Wayland window surface segfaulted (llvmpipe too).
* **ishwl** (`wl-bridge/src/dmabuf.c`): zwp_linux_dmabuf_v1 v4 with default feedback naming
  226:128. Mesa's Wayland EGL platform gets its render node only from that feedback (or
  wl_drm). Imports are refused; frames still arrive as wl_shm. The global is only visible to
  clients that connect through the second socket `$XDG_RUNTIME_DIR/<socket>-gpu` (a global
  filter), so an app opts in with `WAYLAND_DISPLAY=wayland-0-gpu`; `ISHWL_DMABUF=1` shows it to
  every client. It is only created when `/dev/dri/renderD128` opens.

## Building (round 2)

* `gpu/build-third-party.sh [macos] [ios] [iossim]` builds everything host-side from pins:
  virglrenderer at aafa9bd2 + `gpu/patches/virglrenderer-ish.patch`, and MoltenVK 1.4.2 from
  the Khronos release `MoltenVK-all.tar` (sha256-checked, unpacked to
  `gpu/third_party/MoltenVK-1.4.2`). Each `gpu/prefix-*` holds static `libvirglrenderer.a` and
  `libMoltenVK.a` plus `.pc` files; virglrenderer is built with `-Dvulkan-dload=false`, so
  MoltenVK is linked in on every platform (the CLI no longer needs Homebrew MoltenVK, a loader
  or VK_ICD_FILENAMES). About 35 s after the one-time download.
* iOS app: `app/VirtGPU.xcconfig` (included by `app/AppARM64.xcconfig`) sets
  `ISH_VIRTGPU = enabled` and the per-SDK prefix and link flags; `app/xcode-meson.sh` passes
  `-Dvirtgpu` and `-Dpkg_config_path` to the meson build and adds a host `pkg-config` to old
  cross files. Build without: `ISH_VIRTGPU=disabled` (xcconfig or xcodebuild argument).
* CLI: `meson setup build-gpu -Dguest_arch=arm64 -Dvirtgpu=enabled
  -Dpkg_config_path=$PWD/gpu/prefix-macos/lib/pkgconfig` (`--clearcache` after rebuilding a
  prefix: meson caches the static dependency).
* Entitlements: none needed for Metal. Buffers are ordinary `MTLDevice` allocations
  (`newBufferWithBytesNoCopy` on shm/tmp-file mappings); MTLHeaps are not used.
  `com.apple.developer.kernel.increased-memory-limit` would only matter for large GPU working
  sets (blob memory counts toward the app's jetsam footprint);
  `extended-virtual-addressing` is unrelated (guest blob mappings are ordinary host mmaps).

## Guest userspace

`gpu/rootfs-add-gpu.sh IN.tar.gz OUT.tar.gz` (fakefsify, `apk add` inside the emulator,
unfakefsify; about a minute) adds the pinned edge Mesa (`MESA=` in the script; 26.2.4-r0
since edge dropped 26.2.3-r1 on 2026-10-03) (venus ICD, zink in
mesa-dri-gallium, EGL/GLES/GL/GBM), upgrades libxcb and wayland-libs-client from edge (Mesa 26
needs newer symbols; musl cannot express that, so apk would not), vulkan-loader and
vulkan-tools, and `/etc/profile.d/gpu.sh`:

* `VK_ICD_FILENAMES` = the Venus ICD (lavapipe stays installed but is not enumerated);
* `MESA_LOADER_DRIVER_OVERRIDE=zink` (the node's own DRI driver, virgl `virtio_gpu`, needs a
  capset this device does not offer);
* `MESA_VK_WSI_DEBUG=sw` (Vulkan WSI presents as wl_shm).

All three only when `/dev/dri/renderD128` exists. `wl-bridge/ishwl-session` sources the file
(one line). Example: `gpu/rootfs-gui-lean-gpu-arm64.tar.gz` (469 MB, from
rootfs-gui-lean-arm64.tar.gz).

## Firefox (round 2 findings)

* With the EGL device visible (gpu socket), glxtest picks zink on Venus. Frames are presented
  by Mesa's Vulkan WSI into Firefox's GL subsurface (WAYLAND_DEBUG: ~90-280 `mesa vk display
  queue` attaches per run) and ishwl composites them (a desync GL subsurface test,
  `glwin` with `GLWIN_SUB=1`, renders correctly).
* Full GPU WebRender (`gfx.webrender.software=false`): every presented frame is all zeros
  (checked with ishwl forcing subsurfaces opaque). No WebRender/GL errors are logged. zink on
  MoltenVK only reaches GLES 2.0 / GL 2.1 (no transform feedback, geometry shaders, logicOp,
  primitive-restart disable), and the `MESA_GLES_VERSION_OVERRIDE=3.0` WebRender needs is not
  backed by those features. Disabling partial present/buffer age does not change it.
* Software WebRender + GL compositor (`gfx.webrender.software.opengl=true`) works on the GPU:
  pages render (example.com) and the GL compositor's frames go through zink/Venus. It is not
  faster here: a 150-layer CSS animation runs at 1.4 rAF fps vs 2.0 fps with plain software
  WebRender, because rasterization (SWGL) is still emulated CPU work.
* Decision: Firefox stays on software WebRender by default (wl-bridge/firefox-prefs.js is
  unchanged); the dmabuf global is per-client opt-in so it cannot affect Firefox unless asked.

## Zero-copy present (not implemented; plan)

Today a GPU frame is copied three times: Venus WSI (`MESA_VK_WSI_DEBUG=sw`) copies the
swapchain image into a wl_shm buffer in guest code, ishwl copies the damage into the view
file in guest code, and LinuxGUIBridge copies once natively. The first two run emulated.
Plan:
1. Let Venus WSI export swapchain images as dma-bufs (needs the guest's
   EXT_external_memory_dma_buf to be real for linear, host-visible images: the blob is
   already a host shm/MTLBuffer) and let ishwl import them through
   `zwp_linux_buffer_params_v1` when the fd is a virtgpu PRIME fd.
2. ishwl sends `frame-gpu <view> <res_id> ...` instead of copying; LinuxGUIBridge resolves the
   resource through a small emulator API (`virtgpu_blob_lookup(res_id)` → host pointer /
   MTLBuffer) — same process, no IPC — and wraps it in an IOSurface-backed `CALayer.contents`
   or blits it with Metal.
3. Release the wl_buffer when the layer has taken its copy (or on the next frame for true
   zero-copy with an IOSurface).

## Plan for the rest

* Firefox GPU WebRender: find why its zink frames are empty (WR shader/texture paths needing
  real GLES 3 features), e.g. with `MOZ_LOG=webrender` debug builds or apitrace in the guest.
* GL 3.x: zink on MoltenVK reports GL 2.1 / GLES 2.0 (no transform feedback, geometry
  shaders, logicOp). `MESA_GLES_VERSION_OVERRIDE=3.0` is enough for Firefox's glxtest;
  GTK3 GtkGLArea (GL 3.2 core) aborts with the override.
* Zero-copy present: see above.
* On hardware: check `shm_open` vs the TMPDIR fallback and the jetsam footprint.
