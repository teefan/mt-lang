# frozen_string_literal: true

module MilkTea
  module RawBindings
    def self.default_bindings(root: MilkTea.root)
      vendored_raylib = MilkTea::VendoredRaylib
      vendored_raylib_library = vendored_raylib.library(root:)
      vendored_sdl3 = MilkTea::VendoredSDL3
      vendored_sdl3_library = vendored_sdl3.library(root:)
      vendored_glfw = MilkTea::VendoredGLFW
      vendored_glfw_library = vendored_glfw.library(root:)
      vendored_box2d = MilkTea::VendoredBox2D
      vendored_box2d_library = vendored_box2d.library(root:)
      vendored_cjson = MilkTea::VendoredCJSON
      vendored_cjson_library = vendored_cjson.library(root:)
      vendored_flecs = MilkTea::VendoredFlecs
      vendored_flecs_library = vendored_flecs.library(root:)
      vendored_libuv = MilkTea::VendoredLibUV
      vendored_libuv_library = vendored_libuv.library(root:)
      vendored_pcre2 = MilkTea::VendoredPCRE2
      vendored_pcre2_library = vendored_pcre2.library(root:)
      vendored_tracy = MilkTea::VendoredTracy
      vendored_tracy_library = vendored_tracy.library(root:)

      raylib_field_type_overrides = {
        "Mesh" => { "indices" => "ptr[ushort]?" },
      }.freeze

      libuv_fs_callback_functions = %w[
        uv_fs_close
        uv_fs_open
        uv_fs_read
        uv_fs_unlink
        uv_fs_write
        uv_fs_copyfile
        uv_fs_mkdir
        uv_fs_mkdtemp
        uv_fs_mkstemp
        uv_fs_rmdir
        uv_fs_scandir
        uv_fs_opendir
        uv_fs_readdir
        uv_fs_closedir
        uv_fs_stat
        uv_fs_fstat
        uv_fs_rename
        uv_fs_fsync
        uv_fs_fdatasync
        uv_fs_ftruncate
        uv_fs_sendfile
        uv_fs_access
        uv_fs_chmod
        uv_fs_utime
        uv_fs_futime
        uv_fs_lutime
        uv_fs_lstat
        uv_fs_link
        uv_fs_symlink
        uv_fs_readlink
        uv_fs_realpath
        uv_fs_fchmod
        uv_fs_chown
        uv_fs_fchown
        uv_fs_lchown
        uv_fs_statfs
      ].freeze

      libuv_fs_param_overrides = libuv_fs_callback_functions.each_with_object({}) do |function_name, overrides|
        overrides[function_name] = {
          "loop" => "ptr[uv_loop_t]?",
          "cb" => "uv_fs_cb?",
        }
      end.freeze

      libuv_field_type_overrides = {
        "uv_fs_s" => {
          "loop" => "ptr[uv_loop_t]?",
          "cb" => "uv_fs_cb?",
        },
      }.freeze

      libuv_function_param_overrides = {
        "uv_getaddrinfo" => {
          "node" => "cstr?",
          "service" => "cstr?",
          "hints" => "const_ptr[addrinfo]?",
        },
        "uv_udp_send" => { "addr" => "const_ptr[sockaddr]?" },
        "uv_udp_try_send" => { "addr" => "const_ptr[sockaddr]?" },
        "uv_freeaddrinfo" => { "ai" => "ptr[addrinfo]?" },
      }.merge(libuv_fs_param_overrides).freeze

      libuv_function_return_overrides = {
        "uv_default_loop" => "ptr[uv_loop_t]?",
        "uv_loop_new" => "ptr[uv_loop_t]?",
        "uv_handle_get_data" => "ptr[void]?",
        "uv_req_get_data" => "ptr[void]?",
        "uv_dlerror" => "cstr?",
        "uv_key_get" => "ptr[void]?",
        "uv_loop_get_data" => "ptr[void]?",
      }.freeze

      raylib_function_param_overrides = {
        "LoadAutomationEventList" => { "fileName" => "cstr?" },
        "LoadFontEx" => { "codepoints" => "ptr[int]?" },
        "LoadFontFromMemory" => { "codepoints" => "ptr[int]?" },
        "LoadFontData" => { "codepoints" => "ptr[int]?" },
        "LoadShader" => {
          "vsFileName" => "cstr?",
          "fsFileName" => "cstr?",
        },
        "LoadShaderFromMemory" => {
          "vsCode" => "cstr?",
          "fsCode" => "cstr?",
        },
      }.freeze

      raylib_function_return_overrides = {
        "LoadRandomSequence" => "ptr[int]?",
        "MemAlloc" => "ptr[void]?",
        "MemRealloc" => "ptr[void]?",
        "LoadFileData" => "ptr[ubyte]?",
        "LoadFileText" => "ptr[char]?",
        "CompressData" => "ptr[ubyte]?",
        "DecompressData" => "ptr[ubyte]?",
        "EncodeDataBase64" => "ptr[char]?",
        "DecodeDataBase64" => "ptr[ubyte]?",
        "ExportImageToMemory" => "ptr[ubyte]?",
        "LoadImageColors" => "ptr[Color]?",
        "LoadImagePalette" => "ptr[Color]?",
        "LoadUTF8" => "ptr[char]?",
        "LoadCodepoints" => "ptr[int]?",
        "LoadMaterials" => "ptr[Material]?",
        "LoadModelAnimations" => "ptr[ModelAnimation]?",
        "LoadWaveSamples" => "ptr[float]?",
      }.freeze

      raygui_function_return_overrides = raylib_function_return_overrides.merge(
        "GuiLoadIcons" => "ptr[ptr[char]]?",
      ).freeze

      sdl3_documented_function_param_overrides = {
        "SDL_AcquireGPUSwapchainTexture" => {
          "swapchain_texture_width" => "ptr[uint]?",
          "swapchain_texture_height" => "ptr[uint]?",
        },
        "SDL_BeginGPURenderPass" => { "depth_stencil_target_info" => "const_ptr[SDL_GPUDepthStencilTargetInfo]?" },
        "SDL_BlitSurface" => {
          "srcrect" => "const_ptr[SDL_Rect]?",
          "dstrect" => "const_ptr[SDL_Rect]?",
        },
        "SDL_BlitSurface9Grid" => {
          "srcrect" => "const_ptr[SDL_Rect]?",
          "dstrect" => "const_ptr[SDL_Rect]?",
        },
        "SDL_BlitSurfaceScaled" => {
          "srcrect" => "const_ptr[SDL_Rect]?",
          "dstrect" => "const_ptr[SDL_Rect]?",
        },
        "SDL_BlitSurfaceTiled" => {
          "srcrect" => "const_ptr[SDL_Rect]?",
          "dstrect" => "const_ptr[SDL_Rect]?",
        },
        "SDL_BlitSurfaceTiledWithScale" => {
          "srcrect" => "const_ptr[SDL_Rect]?",
          "dstrect" => "const_ptr[SDL_Rect]?",
        },
        "SDL_ConvertSurfaceAndColorspace" => { "palette" => "ptr[SDL_Palette]?" },
        "SDL_CreateGPUDevice" => { "name" => "cstr?" },
        "SDL_CreateGPURenderer" => {
          "device" => "ptr[SDL_GPUDevice]?",
          "window" => "ptr[SDL_Window]?",
        },
        "SDL_CreateRenderer" => { "name" => "cstr?" },
        "SDL_CreateWindowAndRenderer" => {
          "window" => "ptr[ptr[SDL_Window]]?",
          "renderer" => "ptr[ptr[SDL_Renderer]]?",
        },
        "SDL_EnumerateStorageDirectory" => { "path" => "cstr?" },
        "SDL_GL_LoadLibrary" => { "path" => "cstr?" },
        "SDL_GPUSupportsShaderFormats" => { "name" => "cstr?" },
        "SDL_GetAudioPlaybackDevices" => { "count" => "ptr[int]?" },
        "SDL_GetAudioRecordingDevices" => { "count" => "ptr[int]?" },
        "SDL_GetCameraSupportedFormats" => { "count" => "ptr[int]?" },
        "SDL_GetCameras" => { "count" => "ptr[int]?" },
        "SDL_GetClipboardMimeTypes" => { "num_mime_types" => "ptr[ptr_uint]?" },
        "SDL_GetDateTimeLocalePreferences" => {
          "dateFormat" => "ptr[SDL_DateFormat]?",
          "timeFormat" => "ptr[SDL_TimeFormat]?",
        },
        "SDL_GetDisplays" => { "count" => "ptr[int]?" },
        "SDL_GetFullscreenDisplayModes" => { "count" => "ptr[int]?" },
        "SDL_GetGamepadPowerInfo" => { "percent" => "ptr[int]?" },
        "SDL_GetGamepadTouchpadFinger" => {
          "down" => "ptr[bool]?",
          "x" => "ptr[float]?",
          "y" => "ptr[float]?",
          "pressure" => "ptr[float]?",
        },
        "SDL_GetGamepads" => { "count" => "ptr[int]?" },
        "SDL_GetHaptics" => { "count" => "ptr[int]?" },
        "SDL_GetJoystickPowerInfo" => { "percent" => "ptr[int]?" },
        "SDL_GetJoysticks" => { "count" => "ptr[int]?" },
        "SDL_GetKeyboards" => { "count" => "ptr[int]?" },
        "SDL_GetMice" => { "count" => "ptr[int]?" },
        "SDL_GetPathInfo" => { "info" => "ptr[SDL_PathInfo]?" },
        "SDL_GetPowerInfo" => {
          "seconds" => "ptr[int]?",
          "percent" => "ptr[int]?",
        },
        "SDL_GetPreferredLocales" => { "count" => "ptr[int]?" },
        "SDL_GetRGB" => {
          "palette" => "const_ptr[SDL_Palette]?",
          "r" => "ptr[Uint8]?",
          "g" => "ptr[Uint8]?",
          "b" => "ptr[Uint8]?",
        },
        "SDL_GetRGBA" => {
          "palette" => "const_ptr[SDL_Palette]?",
          "r" => "ptr[Uint8]?",
          "g" => "ptr[Uint8]?",
          "b" => "ptr[Uint8]?",
          "a" => "ptr[Uint8]?",
        },
        "SDL_GetRectEnclosingPoints" => { "clip" => "const_ptr[SDL_Rect]?" },
        "SDL_GetRectEnclosingPointsFloat" => { "clip" => "const_ptr[SDL_FRect]?" },
        "SDL_GetRenderLogicalPresentationRect" => { "rect" => "ptr[SDL_FRect]?" },
        "SDL_GetRenderTextureAddressMode" => {
          "u_mode" => "ptr[SDL_TextureAddressMode]?",
          "v_mode" => "ptr[SDL_TextureAddressMode]?",
        },
        "SDL_GetScancodeFromKey" => { "modstate" => "ptr[SDL_Keymod]?" },
        "SDL_GetSensors" => { "count" => "ptr[int]?" },
        "SDL_GetStoragePathInfo" => { "info" => "ptr[SDL_PathInfo]?" },
        "SDL_GetSurfaceImages" => { "count" => "ptr[int]?" },
        "SDL_GetTextInputArea" => {
          "rect" => "ptr[SDL_Rect]?",
          "cursor" => "ptr[int]?",
        },
        "SDL_GetTouchDevices" => { "count" => "ptr[int]?" },
        "SDL_GetWindowAspectRatio" => {
          "min_aspect" => "ptr[float]?",
          "max_aspect" => "ptr[float]?",
        },
        "SDL_GetWindowBordersSize" => {
          "top" => "ptr[int]?",
          "left" => "ptr[int]?",
          "bottom" => "ptr[int]?",
          "right" => "ptr[int]?",
        },
        "SDL_GetWindowMaximumSize" => {
          "w" => "ptr[int]?",
          "h" => "ptr[int]?",
        },
        "SDL_GetWindowMinimumSize" => {
          "w" => "ptr[int]?",
          "h" => "ptr[int]?",
        },
        "SDL_GetWindowPosition" => {
          "x" => "ptr[int]?",
          "y" => "ptr[int]?",
        },
        "SDL_GetWindowSize" => {
          "w" => "ptr[int]?",
          "h" => "ptr[int]?",
        },
        "SDL_GetWindowSizeInPixels" => {
          "w" => "ptr[int]?",
          "h" => "ptr[int]?",
        },
        "SDL_GetWindows" => { "count" => "ptr[int]?" },
        "SDL_GlobStorageDirectory" => {
          "path" => "cstr?",
          "pattern" => "cstr?",
        },
        "SDL_InsertTrayEntryAt" => { "label" => "cstr?" },
        "SDL_LoadFile_IO" => { "datasize" => "ptr[ptr_uint]?" },
        "SDL_OpenFileStorage" => { "path" => "cstr?" },
        "SDL_PeepEvents" => { "events" => "ptr[SDL_Event]?" },
        "SDL_PollEvent" => { "event" => "ptr[SDL_Event]?" },
        "SDL_ReadProcess" => {
          "datasize" => "ptr[ptr_uint]?",
          "exitcode" => "ptr[int]?",
        },
        "SDL_ReadSurfacePixel" => {
          "r" => "ptr[ubyte]?",
          "g" => "ptr[ubyte]?",
          "b" => "ptr[ubyte]?",
          "a" => "ptr[ubyte]?",
        },
        "SDL_ReadSurfacePixelFloat" => {
          "r" => "ptr[float]?",
          "g" => "ptr[float]?",
          "b" => "ptr[float]?",
          "a" => "ptr[float]?",
        },
        "SDL_RenderFillRect" => { "rect" => "const_ptr[SDL_FRect]?" },
        "SDL_RenderGeometryRaw" => { "indices" => "const_ptr[void]?" },
        "SDL_RenderRect" => { "rect" => "const_ptr[SDL_FRect]?" },
        "SDL_RenderTexture9Grid" => {
          "srcrect" => "const_ptr[SDL_FRect]?",
          "dstrect" => "const_ptr[SDL_FRect]?",
        },
        "SDL_RenderTexture9GridTiled" => {
          "srcrect" => "const_ptr[SDL_FRect]?",
          "dstrect" => "const_ptr[SDL_FRect]?",
        },
        "SDL_RenderTextureAffine" => {
          "origin" => "const_ptr[SDL_FPoint]?",
          "right" => "const_ptr[SDL_FPoint]?",
          "down" => "const_ptr[SDL_FPoint]?",
        },
        "SDL_RenderTextureRotated" => {
          "dstrect" => "const_ptr[SDL_FRect]?",
          "center" => "const_ptr[SDL_FPoint]?",
        },
        "SDL_RenderTextureTiled" => {
          "srcrect" => "const_ptr[SDL_FRect]?",
          "dstrect" => "const_ptr[SDL_FRect]?",
        },
        "SDL_RunApp" => { "argv" => "ptr[ptr[char]]?" },
        "SDL_SaveFile" => { "data" => "const_ptr[void]?" },
        "SDL_SaveFile_IO" => { "data" => "const_ptr[void]?" },
        "SDL_SetAppMetadataProperty" => { "value" => "cstr?" },
        "SDL_SetAssertionHandler" => { "handler" => "SDL_AssertionHandler?" },
        "SDL_SetGPURenderState" => { "state" => "ptr[SDL_GPURenderState]?" },
        "SDL_SetGamepadMapping" => { "mapping" => "cstr?" },
        "SDL_SetLogPriorityPrefix" => { "prefix" => "cstr?" },
        "SDL_SetPointerProperty" => { "value" => "ptr[void]?" },
        "SDL_SetPointerPropertyWithCleanup" => { "value" => "ptr[void]?" },
        "SDL_SetRelativeMouseTransform" => { "callback" => "SDL_MouseMotionTransformCallback?" },
        "SDL_SetStringProperty" => { "value" => "cstr?" },
        "SDL_SetSurfaceClipRect" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_SetTextInputArea" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_SetWindowMouseRect" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_SetWindowShape" => { "shape" => "ptr[SDL_Surface]?" },
        "SDL_ShowOpenFileDialog" => {
          "window" => "ptr[SDL_Window]?",
          "filters" => "const_ptr[SDL_DialogFileFilter]?",
          "default_location" => "cstr?",
        },
        "SDL_ShowOpenFolderDialog" => {
          "window" => "ptr[SDL_Window]?",
          "default_location" => "cstr?",
        },
        "SDL_ShowSaveFileDialog" => {
          "window" => "ptr[SDL_Window]?",
          "filters" => "const_ptr[SDL_DialogFileFilter]?",
          "default_location" => "cstr?",
        },
        "SDL_ShowSimpleMessageBox" => { "window" => "ptr[SDL_Window]?" },
        "SDL_StretchSurface" => {
          "srcrect" => "const_ptr[SDL_Rect]?",
          "dstrect" => "const_ptr[SDL_Rect]?",
        },
        "SDL_UpdateNVTexture" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_UpdateYUVTexture" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_WaitAndAcquireGPUSwapchainTexture" => {
          "swapchain_texture_width" => "ptr[uint]?",
          "swapchain_texture_height" => "ptr[uint]?",
        },
        "SDL_WaitEvent" => { "event" => "ptr[SDL_Event]?" },
        "SDL_WaitEventTimeout" => { "event" => "ptr[SDL_Event]?" },
        "SDL_WaitProcess" => { "exitcode" => "ptr[int]?" },
        "SDL_WaitThread" => { "status" => "ptr[int]?" },
        "SDL_WarpMouseInWindow" => { "window" => "ptr[SDL_Window]?" },
        "SDL_aligned_free" => { "mem" => "ptr[void]?" },
        "SDL_free" => { "mem" => "ptr[void]?" },
        "SDL_realloc" => { "mem" => "ptr[void]?" },
        "SDL_strtok_r" => { "str" => "ptr[char]?" },
      }.freeze

      sdl3_function_param_overrides = {
        "SDL_RunApp" => { "reserved" => "ptr[void]?" },
        "SDL_OpenAudioDevice" => { "spec" => "const_ptr[SDL_AudioSpec]?" },
        "SDL_CreateAudioStream" => { "dst_spec" => "const_ptr[SDL_AudioSpec]?" },
        "SDL_OpenAudioDeviceStream" => { "userdata" => "ptr[void]?" },
        "SDL_PutAudioStreamPlanarData" => { "channel_buffers" => "const_ptr[const_ptr[void]?]" },
        "SDL_StepUTF8" => { "pslen" => "ptr[ptr_uint]?" },
        "SDL_MapRGB" => { "palette" => "const_ptr[SDL_Palette]?" },
        "SDL_MapRGBA" => { "palette" => "const_ptr[SDL_Palette]?" },
        "SDL_FillSurfaceRect" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_UpdateTexture" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_LockTextureToSurface" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_SetRenderViewport" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_SetRenderClipRect" => { "rect" => "const_ptr[SDL_Rect]?" },
        "SDL_OpenCamera" => { "spec" => "const_ptr[SDL_CameraSpec]?" },
        "SDL_SetRenderTarget" => { "texture" => "ptr[SDL_Texture]?" },
        "SDL_RenderTexture" => {
          "srcrect" => "const_ptr[SDL_FRect]?",
          "dstrect" => "const_ptr[SDL_FRect]?",
        },
        "SDL_RenderTextureRotated" => { "srcrect" => "const_ptr[SDL_FRect]?" },
        "SDL_RenderTextureAffine" => { "srcrect" => "const_ptr[SDL_FRect]?" },
        "SDL_RenderGeometry" => {
          "texture" => "ptr[SDL_Texture]?",
          "indices" => "const_ptr[int]?",
        },
        "SDL_RenderReadPixels" => { "rect" => "const_ptr[SDL_Rect]?" },
      }.merge(sdl3_documented_function_param_overrides) { |_function_name, current, documented| current.merge(documented) }.freeze

      sdl3_documented_function_return_overrides = {
        "SDL_AcquireGPUCommandBuffer" => "ptr[SDL_GPUCommandBuffer]?",
        "SDL_AsyncIOFromFile" => "ptr[SDL_AsyncIO]?",
        "SDL_ConvertSurfaceAndColorspace" => "ptr[SDL_Surface]?",
        "SDL_CreateAsyncIOQueue" => "ptr[SDL_AsyncIOQueue]?",
        "SDL_CreateColorCursor" => "ptr[SDL_Cursor]?",
        "SDL_CreateCondition" => "ptr[SDL_Condition]?",
        "SDL_CreateCursor" => "ptr[SDL_Cursor]?",
        "SDL_CreateEnvironment" => "ptr[SDL_Environment]?",
        "SDL_CreateGPUBuffer" => "ptr[SDL_GPUBuffer]?",
        "SDL_CreateGPUComputePipeline" => "ptr[SDL_GPUComputePipeline]?",
        "SDL_CreateGPUDevice" => "ptr[SDL_GPUDevice]?",
        "SDL_CreateGPUDeviceWithProperties" => "ptr[SDL_GPUDevice]?",
        "SDL_CreateGPUGraphicsPipeline" => "ptr[SDL_GPUGraphicsPipeline]?",
        "SDL_CreateGPURenderState" => "ptr[SDL_GPURenderState]?",
        "SDL_CreateGPURenderer" => "ptr[SDL_Renderer]?",
        "SDL_CreateGPUSampler" => "ptr[SDL_GPUSampler]?",
        "SDL_CreateGPUShader" => "ptr[SDL_GPUShader]?",
        "SDL_CreateGPUTexture" => "ptr[SDL_GPUTexture]?",
        "SDL_CreateGPUTransferBuffer" => "ptr[SDL_GPUTransferBuffer]?",
        "SDL_CreateMutex" => "ptr[SDL_Mutex]?",
        "SDL_CreatePalette" => "ptr[SDL_Palette]?",
        "SDL_CreatePopupWindow" => "ptr[SDL_Window]?",
        "SDL_CreateProcess" => "ptr[SDL_Process]?",
        "SDL_CreateProcessWithProperties" => "ptr[SDL_Process]?",
        "SDL_CreateRWLock" => "ptr[SDL_RWLock]?",
        "SDL_CreateRenderer" => "ptr[SDL_Renderer]?",
        "SDL_CreateRendererWithProperties" => "ptr[SDL_Renderer]?",
        "SDL_CreateSemaphore" => "ptr[SDL_Semaphore]?",
        "SDL_CreateSoftwareRenderer" => "ptr[SDL_Renderer]?",
        "SDL_CreateSurface" => "ptr[SDL_Surface]?",
        "SDL_CreateSurfaceFrom" => "ptr[SDL_Surface]?",
        "SDL_CreateSurfacePalette" => "ptr[SDL_Palette]?",
        "SDL_CreateSystemCursor" => "ptr[SDL_Cursor]?",
        "SDL_CreateTextureWithProperties" => "ptr[SDL_Texture]?",
        "SDL_CreateThreadRuntime" => "ptr[SDL_Thread]?",
        "SDL_CreateThreadWithPropertiesRuntime" => "ptr[SDL_Thread]?",
        "SDL_CreateWindow" => "ptr[SDL_Window]?",
        "SDL_CreateWindowWithProperties" => "ptr[SDL_Window]?",
        "SDL_DuplicateSurface" => "ptr[SDL_Surface]?",
        "SDL_EGL_GetCurrentConfig" => "SDL_EGLConfig?",
        "SDL_EGL_GetCurrentDisplay" => "SDL_EGLDisplay?",
        "SDL_EGL_GetWindowSurface" => "SDL_EGLSurface?",
        "SDL_GL_CreateContext" => "SDL_GLContext?",
        "SDL_GetAssertionReport" => "const_ptr[SDL_AssertData]?",
        "SDL_GetAudioDeviceName" => "cstr?",
        "SDL_GetAudioDriver" => "cstr?",
        "SDL_GetAudioPlaybackDevices" => "ptr[SDL_AudioDeviceID]?",
        "SDL_GetAudioRecordingDevices" => "ptr[SDL_AudioDeviceID]?",
        "SDL_GetCameraDriver" => "cstr?",
        "SDL_GetCameraName" => "cstr?",
        "SDL_GetCameraSupportedFormats" => "ptr[ptr[SDL_CameraSpec]]?",
        "SDL_GetClipboardData" => "ptr[void]?",
        "SDL_GetClipboardMimeTypes" => "ptr[ptr[char]]?",
        "SDL_GetCurrentAudioDriver" => "cstr?",
        "SDL_GetCurrentCameraDriver" => "cstr?",
        "SDL_GetCurrentVideoDriver" => "cstr?",
        "SDL_GetCursor" => "ptr[SDL_Cursor]?",
        "SDL_GetDefaultCursor" => "ptr[SDL_Cursor]?",
        "SDL_GetEnvironment" => "ptr[SDL_Environment]?",
        "SDL_GetEnvironmentVariable" => "cstr?",
        "SDL_GetEnvironmentVariables" => "ptr[ptr[char]]?",
        "SDL_GetGPUDeviceDriver" => "cstr?",
        "SDL_GetGPURendererDevice" => "ptr[SDL_GPUDevice]?",
        "SDL_GetGamepadAppleSFSymbolsNameForAxis" => "cstr?",
        "SDL_GetGamepadAppleSFSymbolsNameForButton" => "cstr?",
        "SDL_GetGamepadBindings" => "ptr[ptr[SDL_GamepadBinding]]?",
        "SDL_GetGamepadJoystick" => "ptr[SDL_Joystick]?",
        "SDL_GetGamepadSerial" => "cstr?",
        "SDL_GetGamepadStringForAxis" => "cstr?",
        "SDL_GetGamepadStringForButton" => "cstr?",
        "SDL_GetGamepadStringForType" => "cstr?",
        "SDL_GetGrabbedWindow" => "ptr[SDL_Window]?",
        "SDL_GetHapticFromID" => "ptr[SDL_Haptic]?",
        "SDL_GetHapticName" => "cstr?",
        "SDL_GetHapticNameForID" => "cstr?",
        "SDL_GetHaptics" => "ptr[SDL_HapticID]?",
        "SDL_GetHint" => "cstr?",
        "SDL_GetPixelFormatDetails" => "const_ptr[SDL_PixelFormatDetails]?",
        "SDL_GetProcessInput" => "ptr[SDL_IOStream]?",
        "SDL_GetProcessOutput" => "ptr[SDL_IOStream]?",
        "SDL_GetRenderDriver" => "cstr?",
        "SDL_GetRenderMetalCommandEncoder" => "ptr[void]?",
        "SDL_GetRenderMetalLayer" => "ptr[void]?",
        "SDL_GetRenderTarget" => "ptr[SDL_Texture]?",
        "SDL_GetRenderWindow" => "ptr[SDL_Window]?",
        "SDL_GetRenderer" => "ptr[SDL_Renderer]?",
        "SDL_GetRendererFromTexture" => "ptr[SDL_Renderer]?",
        "SDL_GetRendererName" => "cstr?",
        "SDL_GetSurfaceImages" => "ptr[ptr[SDL_Surface]]?",
        "SDL_GetSurfacePalette" => "ptr[SDL_Palette]?",
        "SDL_GetTLS" => "ptr[void]?",
        "SDL_GetTexturePalette" => "ptr[SDL_Palette]?",
        "SDL_GetTrayEntries" => "ptr[const_ptr[SDL_TrayEntry]]?",
        "SDL_GetTrayMenuParentEntry" => "ptr[SDL_TrayEntry]?",
        "SDL_GetTrayMenuParentTray" => "ptr[SDL_Tray]?",
        "SDL_GetVideoDriver" => "cstr?",
        "SDL_GetWindowFromEvent" => "ptr[SDL_Window]?",
        "SDL_GetWindowFromID" => "ptr[SDL_Window]?",
        "SDL_GetWindowFullscreenMode" => "const_ptr[SDL_DisplayMode]?",
        "SDL_GetWindowMouseRect" => "const_ptr[SDL_Rect]?",
        "SDL_GetWindowParent" => "ptr[SDL_Window]?",
        "SDL_GetWindowSurface" => "ptr[SDL_Surface]?",
        "SDL_GlobDirectory" => "ptr[ptr[char]]?",
        "SDL_GlobStorageDirectory" => "ptr[ptr[char]]?",
        "SDL_IOFromConstMem" => "ptr[SDL_IOStream]?",
        "SDL_IOFromDynamicMem" => "ptr[SDL_IOStream]?",
        "SDL_IOFromFile" => "ptr[SDL_IOStream]?",
        "SDL_IOFromMem" => "ptr[SDL_IOStream]?",
        "SDL_InsertTrayEntryAt" => "ptr[SDL_TrayEntry]?",
        "SDL_LoadBMP" => "ptr[SDL_Surface]?",
        "SDL_LoadBMP_IO" => "ptr[SDL_Surface]?",
        "SDL_LoadFile_IO" => "ptr[void]?",
        "SDL_LoadPNG_IO" => "ptr[SDL_Surface]?",
        "SDL_LoadSurface" => "ptr[SDL_Surface]?",
        "SDL_LoadSurface_IO" => "ptr[SDL_Surface]?",
        "SDL_MapGPUTransferBuffer" => "ptr[void]?",
        "SDL_malloc" => "ptr[void]?",
        "SDL_OpenFileStorage" => "ptr[SDL_Storage]?",
        "SDL_OpenHaptic" => "ptr[SDL_Haptic]?",
        "SDL_OpenHapticFromJoystick" => "ptr[SDL_Haptic]?",
        "SDL_OpenHapticFromMouse" => "ptr[SDL_Haptic]?",
        "SDL_OpenIO" => "ptr[SDL_IOStream]?",
        "SDL_OpenStorage" => "ptr[SDL_Storage]?",
        "SDL_OpenTitleStorage" => "ptr[SDL_Storage]?",
        "SDL_OpenUserStorage" => "ptr[SDL_Storage]?",
        "SDL_ReadProcess" => "ptr[void]?",
        "SDL_RotateSurface" => "ptr[SDL_Surface]?",
        "SDL_ScaleSurface" => "ptr[SDL_Surface]?",
        "SDL_SubmitGPUCommandBufferAndAcquireFence" => "ptr[SDL_GPUFence]?",
        "SDL_aligned_alloc" => "ptr[void]?",
        "SDL_bsearch" => "ptr[void]?",
        "SDL_bsearch_r" => "ptr[void]?",
        "SDL_calloc" => "ptr[void]?",
        "SDL_getenv" => "cstr?",
        "SDL_getenv_unsafe" => "cstr?",
        "SDL_hid_get_device_info" => "ptr[SDL_hid_device_info]?",
        "SDL_hid_open" => "ptr[SDL_hid_device]?",
        "SDL_hid_open_path" => "ptr[SDL_hid_device]?",
        "SDL_iconv_string" => "ptr[char]?",
        "SDL_realloc" => "ptr[void]?",
        "SDL_strcasestr" => "ptr[char]?",
        "SDL_strnstr" => "ptr[char]?",
        "SDL_strrchr" => "ptr[char]?",
        "SDL_strstr" => "ptr[char]?",
        "SDL_strtok_r" => "ptr[char]?",
        "SDL_wcsnstr" => "ptr[int]?",
        "SDL_wcsstr" => "ptr[int]?",
      }.freeze

      sdl3_function_return_overrides = {
        "SDL_LoadPNG" => "ptr[SDL_Surface]?",
        "SDL_ConvertSurface" => "ptr[SDL_Surface]?",
        "SDL_CreateTexture" => "ptr[SDL_Texture]?",
        "SDL_CreateTextureFromSurface" => "ptr[SDL_Texture]?",
        "SDL_CreateAudioStream" => "ptr[SDL_AudioStream]?",
        "SDL_GL_GetProcAddress" => "SDL_FunctionPointer?",
        "SDL_EGL_GetProcAddress" => "SDL_FunctionPointer?",
        "SDL_strdup" => "ptr[char]?",
        "SDL_LoadFile" => "ptr[void]?",
        "SDL_strchr" => "ptr[char]?",
        "SDL_GetClipboardText" => "ptr[char]?",
        "SDL_GetPrimarySelectionText" => "ptr[char]?",
        "SDL_GetPreferredLocales" => "ptr[ptr[SDL_Locale]]?",
        "SDL_GetBasePath" => "cstr?",
        "SDL_GetDisplays" => "ptr[SDL_DisplayID]?",
        "SDL_GetDisplayName" => "cstr?",
        "SDL_GetFullscreenDisplayModes" => "ptr[ptr[SDL_DisplayMode]]?",
        "SDL_GetDesktopDisplayMode" => "const_ptr[SDL_DisplayMode]?",
        "SDL_GetCurrentDisplayMode" => "const_ptr[SDL_DisplayMode]?",
        "SDL_GetWindowICCProfile" => "ptr[void]?",
        "SDL_GetWindows" => "ptr[ptr[SDL_Window]]?",
        "SDL_LoadObject" => "ptr[SDL_SharedObject]?",
        "SDL_LoadFunction" => "SDL_FunctionPointer?",
        "SDL_GL_GetCurrentWindow" => "ptr[SDL_Window]?",
        "SDL_GL_GetCurrentContext" => "SDL_GLContext?",
        "SDL_OpenAudioDeviceStream" => "ptr[SDL_AudioStream]?",
        "SDL_GetKeyboards" => "ptr[SDL_KeyboardID]?",
        "SDL_GetKeyboardNameForID" => "cstr?",
        "SDL_GetMice" => "ptr[SDL_MouseID]?",
        "SDL_GetMouseNameForID" => "cstr?",
        "SDL_GetTouchDevices" => "ptr[SDL_TouchID]?",
        "SDL_GetTouchDeviceName" => "cstr?",
        "SDL_GetTouchFingers" => "ptr[ptr[SDL_Finger]]?",
        "SDL_GetSensors" => "ptr[SDL_SensorID]?",
        "SDL_GetSensorNameForID" => "cstr?",
        "SDL_OpenSensor" => "ptr[SDL_Sensor]?",
        "SDL_GetSensorFromID" => "ptr[SDL_Sensor]?",
        "SDL_GetSensorName" => "cstr?",
        "SDL_GetCameras" => "ptr[SDL_CameraID]?",
        "SDL_OpenCamera" => "ptr[SDL_Camera]?",
        "SDL_AcquireCameraFrame" => "ptr[SDL_Surface]?",
        "SDL_GetJoysticks" => "ptr[SDL_JoystickID]?",
        "SDL_OpenJoystick" => "ptr[SDL_Joystick]?",
        "SDL_GetJoystickFromID" => "ptr[SDL_Joystick]?",
        "SDL_GetJoystickNameForID" => "cstr?",
        "SDL_GetJoystickName" => "cstr?",
        "SDL_GetJoystickPathForID" => "cstr?",
        "SDL_GetJoystickFromPlayerIndex" => "ptr[SDL_Joystick]?",
        "SDL_GetJoystickPath" => "cstr?",
        "SDL_GetJoystickSerial" => "cstr?",
        "SDL_GetGamepadMappings" => "ptr[ptr[char]]?",
        "SDL_GetGamepads" => "ptr[SDL_JoystickID]?",
        "SDL_OpenGamepad" => "ptr[SDL_Gamepad]?",
        "SDL_GetGamepadFromID" => "ptr[SDL_Gamepad]?",
        "SDL_GetGamepadNameForID" => "cstr?",
        "SDL_GetGamepadName" => "cstr?",
        "SDL_GetGamepadPathForID" => "cstr?",
        "SDL_GetGamepadPath" => "cstr?",
        "SDL_GetGamepadMapping" => "ptr[char]?",
        "SDL_GetGamepadMappingForGUID" => "ptr[char]?",
        "SDL_GetGamepadMappingForID" => "ptr[char]?",
        "SDL_RenderReadPixels" => "ptr[SDL_Surface]?",
      }.merge(sdl3_documented_function_return_overrides).freeze

      glfw_function_param_overrides = {
        "glfwGetError" => { "description" => "ptr[cstr]?" },
        "glfwSetErrorCallback" => { "callback" => "GLFWerrorfun?" },
        "glfwSetMonitorCallback" => { "callback" => "GLFWmonitorfun?" },
        "glfwCreateWindow" => {
          "monitor" => "ptr[GLFWmonitor]?",
          "share" => "ptr[GLFWwindow]?",
        },
        "glfwSetWindowPosCallback" => { "callback" => "GLFWwindowposfun?" },
        "glfwSetWindowSizeCallback" => { "callback" => "GLFWwindowsizefun?" },
        "glfwSetWindowCloseCallback" => { "callback" => "GLFWwindowclosefun?" },
        "glfwSetWindowRefreshCallback" => { "callback" => "GLFWwindowrefreshfun?" },
        "glfwSetWindowFocusCallback" => { "callback" => "GLFWwindowfocusfun?" },
        "glfwSetWindowIconifyCallback" => { "callback" => "GLFWwindowiconifyfun?" },
        "glfwSetWindowMaximizeCallback" => { "callback" => "GLFWwindowmaximizefun?" },
        "glfwSetFramebufferSizeCallback" => { "callback" => "GLFWframebuffersizefun?" },
        "glfwSetWindowContentScaleCallback" => { "callback" => "GLFWwindowcontentscalefun?" },
        "glfwGetCursorPos" => {
          "xpos" => "ptr[double]?",
          "ypos" => "ptr[double]?",
        },
        "glfwSetCursor" => { "cursor" => "ptr[GLFWcursor]?" },
        "glfwSetKeyCallback" => { "callback" => "GLFWkeyfun?" },
        "glfwSetCharCallback" => { "callback" => "GLFWcharfun?" },
        "glfwSetCharModsCallback" => { "callback" => "GLFWcharmodsfun?" },
        "glfwSetMouseButtonCallback" => { "callback" => "GLFWmousebuttonfun?" },
        "glfwSetCursorPosCallback" => { "callback" => "GLFWcursorposfun?" },
        "glfwSetCursorEnterCallback" => { "callback" => "GLFWcursorenterfun?" },
        "glfwSetScrollCallback" => { "callback" => "GLFWscrollfun?" },
        "glfwSetDropCallback" => { "callback" => "GLFWdropfun?" },
        "glfwSetJoystickCallback" => { "callback" => "GLFWjoystickfun?" },
        "glfwMakeContextCurrent" => { "window" => "ptr[GLFWwindow]?" },
      }.freeze

      glfw_function_return_overrides = {
        "glfwSetErrorCallback" => "GLFWerrorfun?",
        "glfwGetMonitors" => "ptr[ptr[GLFWmonitor]]?",
        "glfwGetPrimaryMonitor" => "ptr[GLFWmonitor]?",
        "glfwGetMonitorName" => "cstr?",
        "glfwGetMonitorUserPointer" => "ptr[void]?",
        "glfwSetMonitorCallback" => "GLFWmonitorfun?",
        "glfwGetVideoModes" => "const_ptr[GLFWvidmode]?",
        "glfwGetVideoMode" => "const_ptr[GLFWvidmode]?",
        "glfwGetGammaRamp" => "const_ptr[GLFWgammaramp]?",
        "glfwCreateWindow" => "ptr[GLFWwindow]?",
        "glfwGetWindowTitle" => "cstr?",
        "glfwGetWindowMonitor" => "ptr[GLFWmonitor]?",
        "glfwGetWindowUserPointer" => "ptr[void]?",
        "glfwSetWindowPosCallback" => "GLFWwindowposfun?",
        "glfwSetWindowSizeCallback" => "GLFWwindowsizefun?",
        "glfwSetWindowCloseCallback" => "GLFWwindowclosefun?",
        "glfwSetWindowRefreshCallback" => "GLFWwindowrefreshfun?",
        "glfwSetWindowFocusCallback" => "GLFWwindowfocusfun?",
        "glfwSetWindowIconifyCallback" => "GLFWwindowiconifyfun?",
        "glfwSetWindowMaximizeCallback" => "GLFWwindowmaximizefun?",
        "glfwSetFramebufferSizeCallback" => "GLFWframebuffersizefun?",
        "glfwSetWindowContentScaleCallback" => "GLFWwindowcontentscalefun?",
        "glfwGetKeyName" => "cstr?",
        "glfwCreateCursor" => "ptr[GLFWcursor]?",
        "glfwCreateStandardCursor" => "ptr[GLFWcursor]?",
        "glfwSetKeyCallback" => "GLFWkeyfun?",
        "glfwSetCharCallback" => "GLFWcharfun?",
        "glfwSetCharModsCallback" => "GLFWcharmodsfun?",
        "glfwSetMouseButtonCallback" => "GLFWmousebuttonfun?",
        "glfwSetCursorPosCallback" => "GLFWcursorposfun?",
        "glfwSetCursorEnterCallback" => "GLFWcursorenterfun?",
        "glfwSetScrollCallback" => "GLFWscrollfun?",
        "glfwSetDropCallback" => "GLFWdropfun?",
        "glfwGetJoystickAxes" => "const_ptr[float]?",
        "glfwGetJoystickButtons" => "const_ptr[ubyte]?",
        "glfwGetJoystickHats" => "const_ptr[ubyte]?",
        "glfwGetJoystickName" => "cstr?",
        "glfwGetJoystickGUID" => "cstr?",
        "glfwGetJoystickUserPointer" => "ptr[void]?",
        "glfwSetJoystickCallback" => "GLFWjoystickfun?",
        "glfwGetGamepadName" => "cstr?",
        "glfwGetClipboardString" => "cstr?",
        "glfwGetCurrentContext" => "ptr[GLFWwindow]?",
        "glfwGetProcAddress" => "GLFWglproc?",
        "glfwGetRequiredInstanceExtensions" => "ptr[cstr]?",
      }.freeze

      [
        Binding.new(
          name: "raylib",
          module_name: "std.c.raylib",
          binding_path: root.join("std/c/raylib.mt"),
          include_directives: ["raylib.h"],
          link_libraries: ["raylib"],
          vendored_library: vendored_raylib_library,
          compiler_flags: ["-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB"],
          header_candidates: [
            vendored_raylib.source_root(root:).join("raylib.h").to_s,
          ],
          field_type_overrides: raylib_field_type_overrides,
          function_param_type_overrides: raylib_function_param_overrides,
          function_return_type_overrides: raylib_function_return_overrides,
        ),
        Binding.new(
          name: "raymath",
          module_name: "std.c.raymath",
          binding_path: root.join("std/c/raymath.mt"),
          include_directives: ["raylib.h", "raymath.h"],
          bindgen_defines: ["RAYMATH_STATIC_INLINE"],
          bindgen_include_directives: ["raylib.h"],
          module_imports: [{ module_name: "std.c.raylib", alias: "rl" }],
          link_libraries: ["m"],
          clang_args: ["-I#{vendored_raylib.source_root}", "-include", "raylib.h"],
          compiler_flags: ["-DRAYMATH_STATIC_INLINE"],
          excluded_declaration_names: ["double_t"],
          type_name_overrides: {
            "float3" => "Float3Array",
            "float16" => "Float16Array",
          },
          type_overrides: {
            "Vector2" => "rl.Vector2",
            "Vector3" => "rl.Vector3",
            "Vector4" => "rl.Vector4",
            "Matrix" => "rl.Matrix",
            "Quaternion" => "rl.Quaternion",
          },
          header_candidates: [
            vendored_raylib.source_root.join("raymath.h").to_s,
          ],
          allow_static_inline_functions: true,
        ),
        Binding.new(
          name: "raygui",
          module_name: "std.c.raygui",
          binding_path: root.join("std/c/raygui.mt"),
          include_directives: ["raygui.h"],
          link_libraries: ["raylib", "m"],
          vendored_library: vendored_raylib_library,
          compiler_flags: ["-DGRAPHICS_API_OPENGL_43"],
          implementation_defines: ["RAYGUI_IMPLEMENTATION"],
          header_candidates: [
            vendored_raylib.source_root.dirname.join("examples/shapes/raygui.h").to_s,
          ],
          function_param_type_overrides: raylib_function_param_overrides,
          function_return_type_overrides: raygui_function_return_overrides,
        ),
        Binding.new(
          name: "rlgl",
          module_name: "std.c.rlgl",
          binding_path: root.join("std/c/rlgl.mt"),
          include_directives: ["rlgl.h"],
          link_libraries: ["raylib"],
          vendored_library: vendored_raylib_library,
          compiler_flags: ["-DMT_LANG_GL_REGISTRY_HAVE_RAYLIB", "-DGRAPHICS_API_OPENGL_43"],
          function_param_type_overrides: {
            "rlLoadTexture" => { "data" => "const_ptr[void]?" },
            "rlLoadTextureCubemap" => { "data" => "const_ptr[void]?" },
            "rlLoadShaderBuffer" => { "data" => "const_ptr[void]?" },
            "rlSetRenderBatchActive" => { "batch" => "ptr[rlRenderBatch]?" },
            "rlLoadShaderProgram" => {
              "vsCode" => "cstr?",
              "fsCode" => "cstr?",
            },
          },
          function_return_type_overrides: {
            "rlGetProcAddress" => "ptr[void]?",
          },
          header_candidates: [
            vendored_raylib.source_root.join("rlgl.h").to_s,
          ],
        ),
        Binding.new(
          name: "libc",
          module_name: "std.c.libc",
          binding_path: root.join("std/c/libc.mt"),
          include_directives: ["stdlib.h"],
          compiler_flags: ["-D_GNU_SOURCE"],
          env_var: "LIBC_HEADER",
          function_param_type_overrides: {
            "strtod" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtof" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtol" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoul" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoq" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtouq" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoll" => { "__endptr" => "ptr[ptr[char]]?" },
            "strtoull" => { "__endptr" => "ptr[ptr[char]]?" },
            "realloc" => { "__ptr" => "ptr[void]?" },
            "reallocarray" => { "__ptr" => "ptr[void]?" },
            "free" => { "__ptr" => "ptr[void]?" },
          },
          function_return_type_overrides: {
            "malloc" => "ptr[void]?",
            "calloc" => "ptr[void]?",
            "realloc" => "ptr[void]?",
            "reallocarray" => "ptr[void]?",
            "aligned_alloc" => "ptr[void]?",
          },
          header_candidates: [
            "/usr/include/stdlib.h",
            "/usr/local/include/stdlib.h",
          ],
        ),
        Binding.new(
          name: "ctype",
          module_name: "std.c.ctype",
          binding_path: root.join("std/c/ctype.mt"),
          declaration_name_prefixes: ["mt_ctype_"],
          include_directives: ["ctype_bindgen.h"],
          allow_static_inline_functions: true,
          header_candidates: [
            root.join("std/c/ctype_bindgen.h").to_s,
          ],
        ),
        Binding.new(
          name: "errno",
          module_name: "std.c.errno",
          binding_path: root.join("std/c/errno.mt"),
          declaration_name_prefixes: ["MT_ERRNO_", "mt_errno_"],
          include_directives: ["errno_bindgen.h"],
          allow_static_inline_functions: true,
          function_return_type_overrides: {
            "mt_errno_strerror" => "cstr?",
          },
          header_candidates: [
            root.join("std/c/errno_bindgen.h").to_s,
          ],
        ),
        Binding.new(
          name: "math",
          module_name: "std.c.math",
          binding_path: root.join("std/c/math.mt"),
          declaration_name_prefixes: ["mt_math_"],
          include_directives: ["math_bindgen.h"],
          allow_static_inline_functions: true,
          link_libraries: ["m"],
          header_candidates: [
            root.join("std/c/math_bindgen.h").to_s,
          ],
        ),
        Binding.new(
          name: "string",
          module_name: "std.c.string",
          binding_path: root.join("std/c/string.mt"),
          declaration_name_prefixes: ["mt_string_"],
          include_directives: ["string_bindgen.h"],
          allow_static_inline_functions: true,
          function_return_type_overrides: {
            "mt_string_memchr" => "ptr[void]?",
            "mt_string_strchr" => "ptr[char]?",
            "mt_string_strrchr" => "ptr[char]?",
            "mt_string_strstr" => "ptr[char]?",
          },
          header_candidates: [
            root.join("std/c/string_bindgen.h").to_s,
          ],
        ),
        Binding.new(
          name: "sdl3",
          module_name: "std.c.sdl3",
          binding_path: root.join("std/c/sdl3.mt"),
          include_directives: ["SDL3/SDL.h", "SDL3/SDL_main.h"],
          bindgen_defines: ["SDL_MAIN_HANDLED=1"],
          bindgen_include_directives: ["SDL3/SDL_main.h"],
          link_libraries: ["SDL3"],
          prepare: lambda do |_binding, **|
            vendored_sdl3.source(root:).bootstrap!
          end,
          vendored_library: vendored_sdl3_library,
          clang_args: vendored_sdl3.include_flags(root:),
          compiler_flags: ["-DSDL_MAIN_HANDLED=1", "-DMT_LANG_GL_REGISTRY_HAVE_SDL3", *vendored_sdl3.include_flags(root:)],
          tracked_header_paths: [
            vendored_sdl3.header_root(root:).join("SDL.h").to_s,
            vendored_sdl3.header_root(root:).join("SDL_main.h").to_s,
          ],
          tracked_header_prefixes: [
            vendored_sdl3.header_root(root:).to_s,
          ],
          declaration_name_prefixes: ["SDL_", "Sint", "Uint"],
          function_param_type_overrides: sdl3_function_param_overrides,
          function_return_type_overrides: sdl3_function_return_overrides,
          header_candidates: [
            vendored_sdl3.header_root(root:).join("SDL.h").to_s,
          ],
        ),
        Binding.new(
          name: "glfw",
          module_name: "std.c.glfw",
          binding_path: root.join("std/c/glfw.mt"),
          include_directives: ["GLFW/glfw3.h"],
          link_libraries: ["glfw3"],
          prepare: lambda do |_binding, **|
            vendored_glfw.source(root:).bootstrap!
          end,
          vendored_library: vendored_glfw_library,
          clang_args: vendored_glfw.include_flags(root:),
          compiler_flags: ["-DMT_LANG_GL_REGISTRY_HAVE_GLFW", *vendored_glfw.include_flags(root:)],
          tracked_header_paths: [
            vendored_glfw.header_root(root:).join("glfw3.h").to_s,
          ],
          tracked_header_prefixes: [
            vendored_glfw.header_root(root:).to_s,
          ],
          declaration_name_prefixes: ["GLFW", "glfw"],
          function_param_type_overrides: glfw_function_param_overrides,
          function_return_type_overrides: glfw_function_return_overrides,
          header_candidates: [
            vendored_glfw.header_root(root:).join("glfw3.h").to_s,
          ],
        ),
        Binding.new(
          name: "gl",
          module_name: "std.c.gl",
          binding_path: root.join("std/c/gl.mt"),
          include_directives: ["gl_registry_helpers.h"],
          link_libraries: [],
          implementation_defines: [MilkTea::OpenGLRegistry::IMPLEMENTATION_DEFINE],
          tracked_header_paths: [
            MilkTea::OpenGLRegistry.helper_header_path(root:).to_s,
          ],
          declaration_name_prefixes: ["GL", "gl", "mt_gl_"],
          header_candidates: [
            MilkTea::OpenGLRegistry.helper_header_path(root:).to_s,
          ],
          prepare: lambda do |_binding, **|
            MilkTea::OpenGLRegistry.prepare!(root:)
          end,
        ),
        Binding.new(
          name: "box2d",
          module_name: "std.c.box2d",
          binding_path: root.join("std/c/box2d.mt"),
          include_directives: ["box2d/box2d.h"],
          link_libraries: ["box2d"],
          vendored_library: vendored_box2d_library,
          clang_args: vendored_box2d.include_flags(root:),
          compiler_flags: vendored_box2d.include_flags(root:),
          tracked_header_paths: [
            vendored_box2d.header_root(root:).join("box2d.h").to_s,
          ],
          tracked_header_prefixes: [
            vendored_box2d.header_root(root:).to_s,
          ],
          declaration_name_prefixes: ["b2", "B2_"],
          header_candidates: [
            vendored_box2d.header_root(root:).join("box2d.h").to_s,
          ],
        ),
        Binding.new(
          name: "cjson",
          module_name: "std.c.cjson",
          binding_path: root.join("std/c/cjson.mt"),
          include_directives: ["cJSON.h"],
          link_libraries: ["cjson"],
          vendored_library: vendored_cjson_library,
          declaration_name_prefixes: ["cJSON", "CJSON_"],
          function_return_type_overrides: {
            "cJSON_Parse" => "ptr[cJSON]?",
            "cJSON_ParseWithLength" => "ptr[cJSON]?",
            "cJSON_ParseWithOpts" => "ptr[cJSON]?",
            "cJSON_ParseWithLengthOpts" => "ptr[cJSON]?",
            "cJSON_Print" => "ptr[char]?",
            "cJSON_PrintUnformatted" => "ptr[char]?",
            "cJSON_PrintBuffered" => "ptr[char]?",
            "cJSON_GetErrorPtr" => "cstr?",
            "cJSON_GetStringValue" => "cstr?",
            "cJSON_GetArrayItem" => "ptr[cJSON]?",
            "cJSON_GetObjectItem" => "ptr[cJSON]?",
            "cJSON_GetObjectItemCaseSensitive" => "ptr[cJSON]?",
            "cJSON_DetachItemViaPointer" => "ptr[cJSON]?",
            "cJSON_DetachItemFromArray" => "ptr[cJSON]?",
            "cJSON_DetachItemFromObject" => "ptr[cJSON]?",
            "cJSON_DetachItemFromObjectCaseSensitive" => "ptr[cJSON]?",
            "cJSON_CreateNull" => "ptr[cJSON]?",
            "cJSON_CreateTrue" => "ptr[cJSON]?",
            "cJSON_CreateFalse" => "ptr[cJSON]?",
            "cJSON_CreateBool" => "ptr[cJSON]?",
            "cJSON_CreateNumber" => "ptr[cJSON]?",
            "cJSON_CreateString" => "ptr[cJSON]?",
            "cJSON_CreateRaw" => "ptr[cJSON]?",
            "cJSON_CreateArray" => "ptr[cJSON]?",
            "cJSON_CreateObject" => "ptr[cJSON]?",
            "cJSON_CreateStringReference" => "ptr[cJSON]?",
            "cJSON_CreateObjectReference" => "ptr[cJSON]?",
            "cJSON_CreateArrayReference" => "ptr[cJSON]?",
            "cJSON_AddNullToObject" => "ptr[cJSON]?",
            "cJSON_AddTrueToObject" => "ptr[cJSON]?",
            "cJSON_AddFalseToObject" => "ptr[cJSON]?",
            "cJSON_AddBoolToObject" => "ptr[cJSON]?",
            "cJSON_AddNumberToObject" => "ptr[cJSON]?",
            "cJSON_AddStringToObject" => "ptr[cJSON]?",
            "cJSON_AddRawToObject" => "ptr[cJSON]?",
            "cJSON_AddObjectToObject" => "ptr[cJSON]?",
            "cJSON_AddArrayToObject" => "ptr[cJSON]?",
          },
          header_candidates: [
            vendored_cjson.source_root.join("cJSON.h").to_s,
          ],
        ),
        Binding.new(
          name: "flecs",
          module_name: "std.c.flecs",
          binding_path: root.join("std/c/flecs.mt"),
          include_directives: ["flecs.h"],
          link_libraries: ["flecs"],
          vendored_library: vendored_flecs_library,
          clang_args: vendored_flecs.include_flags(root:),
          compiler_flags: vendored_flecs.include_flags(root:),
          tracked_header_paths: [
            vendored_flecs.header_path(root:).to_s,
          ],
          tracked_header_prefixes: [
            vendored_flecs.include_root(root:).to_s,
          ],
          declaration_name_prefixes: ["ecs_", "Ecs", "ECS_", "FLECS_"],
          header_candidates: [
            vendored_flecs.header_path(root:).to_s,
          ],
        ),
        Binding.new(
          name: "libuv",
          module_name: "std.c.libuv",
          binding_path: root.join("std/c/libuv.mt"),
          include_directives: ["uv.h"],
          link_libraries: ["uv"],
          prepare: lambda do |_binding, **|
            vendored_libuv.source(root:).bootstrap!
          end,
          vendored_library: vendored_libuv_library,
          clang_args: vendored_libuv.include_flags(root:),
          compiler_flags: vendored_libuv.include_flags(root:),
          tracked_header_paths: [
            vendored_libuv.header_path(root:).to_s,
          ],
          tracked_header_prefixes: [
            vendored_libuv.include_root(root:).to_s,
          ],
          declaration_name_prefixes: ["uv_", "UV_"],
          type_overrides: {
            "cc_t" => "ubyte",
            "DIR" => "void",
            "in_addr" => "uint",
            "in6_addr" => "array[ubyte, 16]",
            "speed_t" => "uint",
            "tcflag_t" => "uint",
            "termios" => "void",
          },
          function_param_type_overrides: libuv_function_param_overrides,
          function_return_type_overrides: libuv_function_return_overrides,
          field_type_overrides: libuv_field_type_overrides,
          header_candidates: [
            vendored_libuv.header_path(root:).to_s,
          ],
        ),
        Binding.new(
          name: "enet",
          module_name: "std.c.enet",
          binding_path: root.join("std/c/enet.mt"),
          include_directives: ["enet/enet.h"],
          link_libraries: ["enet"],
          declaration_name_prefixes: ["enet_", "ENET_", "ENet", "_ENet"],
          tracked_header_paths: [
            "/usr/include/enet/enet.h",
            "/usr/local/include/enet/enet.h",
          ],
          tracked_header_prefixes: [
            "/usr/include/enet",
            "/usr/local/include/enet",
          ],
          header_candidates: [
            "/usr/include/enet/enet.h",
            "/usr/local/include/enet/enet.h",
          ],
        ),
        Binding.new(
          name: "zstd",
          module_name: "std.c.zstd",
          binding_path: root.join("std/c/zstd.mt"),
          include_directives: ["zstd.h"],
          link_libraries: ["zstd"],
          declaration_name_prefixes: ["ZSTD_", "ZSTD", "ZDICTLIB_", "ZDICT_", "HUF_", "FSE_"],
          tracked_header_paths: [
            "/usr/include/zstd.h",
            "/usr/include/zstd_errors.h",
            "/usr/local/include/zstd.h",
            "/usr/local/include/zstd_errors.h",
          ],
          header_candidates: [
            "/usr/include/zstd.h",
            "/usr/local/include/zstd.h",
          ],
        ),
        Binding.new(
          name: "sqlite3",
          module_name: "std.c.sqlite3",
          binding_path: root.join("std/c/sqlite3.mt"),
          include_directives: ["sqlite3.h"],
          bindgen_defines: ["SQLITE_OMIT_LOAD_EXTENSION"],
          link_libraries: ["sqlite3"],
          declaration_name_prefixes: ["sqlite3", "SQLITE_"],
          header_candidates: [
            "/usr/include/sqlite3.h",
            "/usr/local/include/sqlite3.h",
          ],
        ),
        Binding.new(
          name: "curl",
          module_name: "std.c.curl",
          binding_path: root.join("std/c/curl.mt"),
          include_directives: ["curl/curl.h"],
          link_libraries: ["curl"],
          declaration_name_prefixes: ["curl_", "curlfiletype", "CURL", "CURLOPT_", "CURLINFO_", "CURLM", "CURLSH"],
          type_overrides: {
            "curlfiletype" => "int",
            "curl_easytype" => "int",
            "CURLUcode" => "int",
          },
          field_type_overrides: {
            "curl_fileinfo" => { "filetype" => "int" },
            "curl_easyoption" => { "type" => "int" },
          },
          header_candidates: [
            "/usr/include/curl/curl.h",
            "/usr/local/include/curl/curl.h",
          ],
        ),
        Binding.new(
          name: "pcre2",
          module_name: "std.c.pcre2",
          binding_path: root.join("std/c/pcre2.mt"),
          include_directives: ["pcre2.h"],
          bindgen_defines: ["PCRE2_CODE_UNIT_WIDTH=8"],
          link_libraries: ["pcre2-8"],
          prepare: lambda do |_binding, **|
            vendored_pcre2.source(root:).bootstrap!
          end,
          vendored_library: vendored_pcre2_library,
          clang_args: vendored_pcre2.include_flags(root:),
          compiler_flags: ["-DPCRE2_CODE_UNIT_WIDTH=8", *vendored_pcre2.include_flags(root:)],
          tracked_header_paths: [
            vendored_pcre2.header_path(root:).to_s,
          ],
          tracked_header_prefixes: [
            vendored_pcre2.include_root(root:).to_s,
          ],
          declaration_name_prefixes: ["pcre2_", "PCRE2_"],
          header_candidates: [
            vendored_pcre2.header_path(root:).to_s,
          ],
        ),
        Binding.new(
          name: "steamworks",
          module_name: "std.c.steamworks",
          binding_path: root.join("std/c/steamworks.mt"),
          include_directives: ["steamworks.h"],
          link_libraries: MilkTea::Steamworks.default_link_libraries,
          allow_static_inline_functions: true,
          vendored_library: MilkTea::VendoredSteamworks.library(root:),
          tracked_header_paths: [
            MilkTea::Steamworks.helper_header_path(root:).to_s,
          ],
          header_candidates: [
            MilkTea::Steamworks.helper_header_path(root:).to_s,
          ],
          prepare: lambda do |_binding, env:, **|
            MilkTea::Steamworks.prepare!(root:, env:)
          end,
        ),
        Binding.new(
          name: "miniaudio",
          module_name: "std.c.miniaudio",
          binding_path: root.join("std/c/miniaudio.mt"),
          include_directives: ["miniaudio.h"],
          bindgen_defines: ["MA_NO_FLAC", "MA_NO_MP3"],
          implementation_defines: ["MINIAUDIO_IMPLEMENTATION", "MA_NO_FLAC", "MA_NO_MP3"],
          link_libraries: ["dl", "pthread", "m"],
          declaration_name_prefixes: ["ma_", "MA_"],
          header_candidates: [
            MilkTea.data_root.join("third_party/miniaudio-upstream/miniaudio.h").to_s,
          ],
        ),
        Binding.new(
          name: "tracy",
          module_name: "std.c.tracy",
          binding_path: root.join("std/c/tracy.mt"),
          include_directives: ["TracyC.h"],
          link_libraries: ["tracyclient", "stdc++"],
          implementation_defines: ["TRACY_ENABLE"],
          vendored_library: vendored_tracy_library,
          prepare: lambda do |_binding, env:, cc:, **|
            UpstreamSources.default_sources(root:).find { |source| source.name == "tracy" }&.bootstrap!
            MilkTea::VendoredTracy.library(root:).prepare!(env:, cc:)
          end,
          header_candidates: [
            MilkTea.data_root.join("third_party/tracy-upstream/public/tracy/TracyC.h").to_s,
          ],
          generator: lambda do |binding, env:, header_path:|
            File.read(binding.binding_path)
          end,
        ),
        Binding.new(
          name: "rres",
          module_name: "std.c.rres",
          binding_path: root.join("std/c/rres.mt"),
          include_directives: ["rres.h"],
          declaration_name_prefixes: ["rres", "RRES_"],
          header_candidates: [
            MilkTea.data_root.join("third_party/rres-upstream/src/rres.h").to_s,
          ],
          prepare: lambda do |_binding, **|
            UpstreamSources.default_sources(root:).find { |source| source.name == "rres" }&.bootstrap!
          end,
        ),
        Binding.new(
          name: "rpng",
          module_name: "std.c.rpng",
          binding_path: root.join("std/c/rpng.mt"),
          include_directives: ["rpng.h"],
          declaration_name_prefixes: ["rpng", "RPNG_"],
          header_candidates: [
            MilkTea.data_root.join("third_party/rpng-upstream/src/rpng.h").to_s,
          ],
          prepare: lambda do |_binding, **|
            UpstreamSources.default_sources(root:).find { |source| source.name == "rpng" }&.bootstrap!
          end,
        ),
      ]
    end
  end
end
