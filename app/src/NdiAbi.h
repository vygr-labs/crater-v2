#pragma once

#include <cstdint>

// Minimal NDI SDK ABI mirror. We dynamically load Processing.NDI.Lib.x64.dll
// at runtime via QLibrary, so this header replicates the few NDI struct +
// enum + function-pointer types we need without requiring the SDK headers
// at build time. Sources: NDI SDK 5.x Processing.NDI.Lib.h.
//
// Keep declarations C-compatible: NDI's exported symbols are extern "C", and
// the function pointer types resolved from QLibrary::resolve() must match
// the SDK's C calling convention. struct layouts are POD; field ordering
// MUST match the SDK header exactly or we'll read garbage.

extern "C" {

// Opaque handle to a sender instance.
typedef void* NDIlib_send_instance_t;

// NDI uses FourCC codes to identify pixel formats. Little-endian packing:
// the first character ends up in the least-significant byte of the uint32_t.
#define NDI_FOURCC(a, b, c, d)                                                  \
    (uint32_t(uint8_t(a))                                                       \
     | (uint32_t(uint8_t(b)) << 8)                                              \
     | (uint32_t(uint8_t(c)) << 16)                                             \
     | (uint32_t(uint8_t(d)) << 24))

enum NDIlib_FourCC_video_type_e {
    NDIlib_FourCC_video_type_BGRA = NDI_FOURCC('B', 'G', 'R', 'A'),
    NDIlib_FourCC_video_type_BGRX = NDI_FOURCC('B', 'G', 'R', 'X'),
    NDIlib_FourCC_video_type_RGBA = NDI_FOURCC('R', 'G', 'B', 'A'),
    NDIlib_FourCC_video_type_RGBX = NDI_FOURCC('R', 'G', 'B', 'X'),
    NDIlib_FourCC_video_type_UYVY = NDI_FOURCC('U', 'Y', 'V', 'Y'),
};

enum NDIlib_frame_format_type_e {
    NDIlib_frame_format_type_progressive  = 1,
    NDIlib_frame_format_type_interleaved  = 0,
    NDIlib_frame_format_type_field_0      = 2,
    NDIlib_frame_format_type_field_1      = 3,
};

// Settings for NDIlib_send_create. p_groups and clock_audio are unused
// today; we still mirror the full struct so the layout matches the SDK.
struct NDIlib_send_create_t {
    const char* p_ndi_name;
    const char* p_groups;
    bool        clock_video;
    bool        clock_audio;
};

// A video frame to send. For uncompressed formats (BGRA et al.) the union
// reads as line_stride_in_bytes; for compressed it'd be data_size_in_bytes.
// We only send uncompressed, so the layout below is correct for our use.
struct NDIlib_video_frame_v2_t {
    int                            xres;
    int                            yres;
    NDIlib_FourCC_video_type_e     FourCC;
    int                            frame_rate_N;
    int                            frame_rate_D;
    float                          picture_aspect_ratio;
    NDIlib_frame_format_type_e     frame_format_type;
    int64_t                        timecode;
    uint8_t*                       p_data;
    int                            line_stride_in_bytes;
    const char*                    p_metadata;
    int64_t                        timestamp;
};

// Tally state — receivers signal whether they have us on PGM (program /
// on-air) or PVW (preview). Producer-side notification only; we never
// flip these ourselves.
struct NDIlib_tally_t {
    bool on_program;
    bool on_preview;
};

// Function pointers we resolve via QLibrary at runtime. The NDI SDK exports
// these as extern "C" symbols inside Processing.NDI.Lib.x64.dll.
typedef bool                       (*NDIlib_initialize_fn)();
typedef void                       (*NDIlib_destroy_fn)();
typedef NDIlib_send_instance_t     (*NDIlib_send_create_fn)(const NDIlib_send_create_t* p_create_settings);
typedef void                       (*NDIlib_send_destroy_fn)(NDIlib_send_instance_t p_instance);
typedef void                       (*NDIlib_send_send_video_v2_fn)(NDIlib_send_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data);
// Async send returns after queueing; the supplied frame buffer must
// remain valid until the NEXT call to this function for the same sender.
// This is the contract that forces two-slot frame buffering on our side.
typedef void                       (*NDIlib_send_send_video_async_v2_fn)(NDIlib_send_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data);
// Blocks until tally state changes or timeout_in_ms elapses, whichever
// is first. Returns true if currently on-air (either program or preview);
// the detailed state is written to *p_tally.
typedef bool                       (*NDIlib_send_get_tally_fn)(NDIlib_send_instance_t p_instance, NDIlib_tally_t* p_tally, uint32_t timeout_in_ms);

}  // extern "C"
