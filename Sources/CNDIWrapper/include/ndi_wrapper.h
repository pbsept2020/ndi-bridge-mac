//
//  ndi_wrapper.h
//  C wrapper for NDI SDK
//

#ifndef ndi_wrapper_h
#define ndi_wrapper_h

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

// ============================================================================
// NDI Video Frame Structure (matches NDIlib_video_frame_v2_t)
// ============================================================================
typedef struct {
    int32_t xres;                    // Resolution X
    int32_t yres;                    // Resolution Y
    uint32_t FourCC;                 // Pixel format FourCC
    int32_t frame_rate_N;            // Frame rate numerator
    int32_t frame_rate_D;            // Frame rate denominator
    float picture_aspect_ratio;      // Picture aspect ratio
    int32_t frame_format_type;       // Progressive/interlaced
    int64_t timecode;                // Timecode
    uint8_t* p_data;                 // Pointer to video data
    int32_t line_stride_in_bytes;    // Line stride
    const char* p_metadata;          // Metadata XML
    int64_t timestamp;               // Timestamp in 100ns intervals
} NDIBridgeVideoFrame;

// ============================================================================
// NDI Audio Frame Structure (matches NDIlib_audio_frame_v3_t)
// ============================================================================
typedef struct {
    int32_t sample_rate;             // Sample rate (e.g., 48000)
    int32_t no_channels;             // Number of audio channels
    int32_t no_samples;              // Number of samples per channel
    int64_t timecode;                // Timecode
    uint32_t FourCC;                 // Audio format FourCC
    uint8_t* p_data;                 // Pointer to audio data
    int32_t channel_stride_in_bytes; // Stride between channels (0 = interleaved)
    const char* p_metadata;          // Metadata XML
    int64_t timestamp;               // Timestamp in 100ns intervals
} NDIBridgeAudioFrame;

// ============================================================================
// NDI Source Structure (matches NDIlib_source_t)
// ============================================================================
typedef struct {
    const char* p_ndi_name;          // NDI source name
    const char* p_url_address;       // URL address (can be NULL)
} NDIBridgeSource;

// ============================================================================
// NDI SDK Functions
// ============================================================================

// Initialize NDI SDK
bool ndi_initialize(void);

// Cleanup NDI SDK
void ndi_destroy(void);

// ============================================================================
// NDI Finder Functions
// ============================================================================

void* ndi_find_create(void);
void ndi_find_destroy(void* finder);
int ndi_find_get_sources(void* finder, void** sources, int timeout_ms);

// Get source info at index (returns pointer to internal NDIBridgeSource)
const char* ndi_source_get_name(void* sources, int index);

// ============================================================================
// NDI Receiver Functions
// ============================================================================

void* ndi_receiver_create(void);
void ndi_receiver_destroy(void* receiver);
bool ndi_receiver_connect(void* receiver, void* source);

// Capture video frame - returns frame type (0=none, 1=video, 2=audio, 3=metadata, 4=error)
int ndi_receiver_capture(void* receiver, void* video_frame, void* audio_frame, int timeout_ms);

// Free captured video frame
void ndi_receiver_free_video(void* receiver, void* video_frame);

// Free captured audio frame
void ndi_receiver_free_audio(void* receiver, void* audio_frame);

// ============================================================================
// NDI Sender Functions
// ============================================================================

void* ndi_sender_create(const char* name);
void ndi_sender_destroy(void* sender);
void ndi_sender_send_video(void* sender, void* video_frame);
void ndi_sender_send_audio(void* sender, void* audio_frame);

// ============================================================================
// Video Frame Helper Functions
// ============================================================================

// Allocate a video frame structure
NDIBridgeVideoFrame* ndi_video_frame_create(void);

// Free a video frame structure (not the data, just the struct)
void ndi_video_frame_destroy(NDIBridgeVideoFrame* frame);

// Initialize a video frame for sending
void ndi_video_frame_init(NDIBridgeVideoFrame* frame,
                          int32_t width,
                          int32_t height,
                          uint32_t fourcc,
                          int32_t frame_rate_n,
                          int32_t frame_rate_d,
                          uint8_t* data,
                          int32_t line_stride);

// Get size of video frame structure (for allocation)
size_t ndi_video_frame_size(void);

// ============================================================================
// Audio Frame Helper Functions
// ============================================================================

// Allocate an audio frame structure
NDIBridgeAudioFrame* ndi_audio_frame_create(void);

// Free an audio frame structure (not the data, just the struct)
void ndi_audio_frame_destroy(NDIBridgeAudioFrame* frame);

// Initialize an audio frame for sending
void ndi_audio_frame_init(NDIBridgeAudioFrame* frame,
                          int32_t sample_rate,
                          int32_t no_channels,
                          int32_t no_samples,
                          uint8_t* data,
                          int32_t channel_stride);

// Get size of audio frame structure (for allocation)
size_t ndi_audio_frame_size(void);

#endif /* ndi_wrapper_h */
