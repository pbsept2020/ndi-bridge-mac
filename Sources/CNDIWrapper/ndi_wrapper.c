//
//  ndi_wrapper.c
//  C wrapper implementation for NDI SDK
//

#include "ndi_wrapper.h"
#include <Processing.NDI.Lib.h>
#include <stdlib.h>
#include <string.h>

// Verify structure sizes match at compile time
_Static_assert(sizeof(NDIBridgeVideoFrame) == sizeof(NDIlib_video_frame_v2_t),
               "NDIBridgeVideoFrame size must match NDIlib_video_frame_v2_t");
_Static_assert(sizeof(NDIBridgeAudioFrame) == sizeof(NDIlib_audio_frame_v3_t),
               "NDIBridgeAudioFrame size must match NDIlib_audio_frame_v3_t");

bool ndi_initialize(void) {
    return NDIlib_initialize();
}

void ndi_destroy(void) {
    NDIlib_destroy();
}

void* ndi_find_create(void) {
    NDIlib_find_create_t find_settings;
    find_settings.show_local_sources = true;
    find_settings.p_groups = NULL;
    find_settings.p_extra_ips = NULL;

    return NDIlib_find_create_v2(&find_settings);
}

void ndi_find_destroy(void* finder) {
    if (finder) {
        NDIlib_find_destroy((NDIlib_find_instance_t)finder);
    }
}

int ndi_find_get_sources(void* finder, void** sources, int timeout_ms) {
    if (!finder) return 0;

    // Wait for sources
    NDIlib_find_wait_for_sources((NDIlib_find_instance_t)finder, timeout_ms);

    uint32_t num_sources = 0;
    const NDIlib_source_t* ndi_sources = NDIlib_find_get_current_sources(
        (NDIlib_find_instance_t)finder,
        &num_sources
    );

    if (sources) {
        *sources = (void*)ndi_sources;
    }

    return (int)num_sources;
}

const char* ndi_source_get_name(void* sources, int index) {
    if (!sources || index < 0) return NULL;

    const NDIlib_source_t* ndi_sources = (const NDIlib_source_t*)sources;
    return ndi_sources[index].p_ndi_name;
}

void* ndi_receiver_create(void) {
    NDIlib_recv_create_v3_t recv_settings;
    memset(&recv_settings, 0, sizeof(recv_settings));

    recv_settings.source_to_connect_to.p_ndi_name = NULL;
    recv_settings.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    recv_settings.bandwidth = NDIlib_recv_bandwidth_highest;
    recv_settings.allow_video_fields = false;
    recv_settings.p_ndi_recv_name = "NDI Bridge Receiver";

    return NDIlib_recv_create_v3(&recv_settings);
}

void ndi_receiver_destroy(void* receiver) {
    if (receiver) {
        NDIlib_recv_destroy((NDIlib_recv_instance_t)receiver);
    }
}

bool ndi_receiver_connect(void* receiver, void* source) {
    if (!receiver || !source) return false;

    NDIlib_recv_connect((NDIlib_recv_instance_t)receiver, (const NDIlib_source_t*)source);
    return true;
}

int ndi_receiver_capture(void* receiver, void* video_frame, void* audio_frame, int timeout_ms) {
    if (!receiver) return 0;

    return (int)NDIlib_recv_capture_v3(
        (NDIlib_recv_instance_t)receiver,
        (NDIlib_video_frame_v2_t*)video_frame,
        (NDIlib_audio_frame_v3_t*)audio_frame,
        NULL,
        (uint32_t)timeout_ms
    );
}

void ndi_receiver_free_video(void* receiver, void* video_frame) {
    if (receiver && video_frame) {
        NDIlib_recv_free_video_v2(
            (NDIlib_recv_instance_t)receiver,
            (NDIlib_video_frame_v2_t*)video_frame
        );
    }
}

void ndi_receiver_free_audio(void* receiver, void* audio_frame) {
    if (receiver && audio_frame) {
        NDIlib_recv_free_audio_v3(
            (NDIlib_recv_instance_t)receiver,
            (NDIlib_audio_frame_v3_t*)audio_frame
        );
    }
}

void* ndi_sender_create(const char* name) {
    NDIlib_send_create_t send_settings;
    memset(&send_settings, 0, sizeof(send_settings));

    send_settings.p_ndi_name = name;
    send_settings.clock_video = true;
    send_settings.clock_audio = false;

    return NDIlib_send_create(&send_settings);
}

void ndi_sender_destroy(void* sender) {
    if (sender) {
        NDIlib_send_destroy((NDIlib_send_instance_t)sender);
    }
}

void ndi_sender_send_video(void* sender, void* video_frame) {
    if (sender && video_frame) {
        NDIlib_send_send_video_v2(
            (NDIlib_send_instance_t)sender,
            (const NDIlib_video_frame_v2_t*)video_frame
        );
    }
}

void ndi_sender_send_audio(void* sender, void* audio_frame) {
    if (sender && audio_frame) {
        NDIlib_send_send_audio_v3(
            (NDIlib_send_instance_t)sender,
            (const NDIlib_audio_frame_v3_t*)audio_frame
        );
    }
}

// ============================================================================
// Video Frame Helper Functions
// ============================================================================

NDIBridgeVideoFrame* ndi_video_frame_create(void) {
    NDIBridgeVideoFrame* frame = (NDIBridgeVideoFrame*)calloc(1, sizeof(NDIBridgeVideoFrame));
    return frame;
}

void ndi_video_frame_destroy(NDIBridgeVideoFrame* frame) {
    if (frame) {
        free(frame);
    }
}

void ndi_video_frame_init(NDIBridgeVideoFrame* frame,
                          int32_t width,
                          int32_t height,
                          uint32_t fourcc,
                          int32_t frame_rate_n,
                          int32_t frame_rate_d,
                          uint8_t* data,
                          int32_t line_stride) {
    if (!frame) return;

    frame->xres = width;
    frame->yres = height;
    frame->FourCC = fourcc;
    frame->frame_rate_N = frame_rate_n;
    frame->frame_rate_D = frame_rate_d;
    frame->picture_aspect_ratio = (float)width / (float)height;
    frame->frame_format_type = 1;  // Progressive
    frame->timecode = NDIlib_send_timecode_synthesize;
    frame->p_data = data;
    frame->line_stride_in_bytes = line_stride;
    frame->p_metadata = NULL;
    frame->timestamp = 0;
}

size_t ndi_video_frame_size(void) {
    return sizeof(NDIBridgeVideoFrame);
}

// ============================================================================
// Audio Frame Helper Functions
// ============================================================================

NDIBridgeAudioFrame* ndi_audio_frame_create(void) {
    NDIBridgeAudioFrame* frame = (NDIBridgeAudioFrame*)calloc(1, sizeof(NDIBridgeAudioFrame));
    return frame;
}

void ndi_audio_frame_destroy(NDIBridgeAudioFrame* frame) {
    if (frame) {
        free(frame);
    }
}

void ndi_audio_frame_init(NDIBridgeAudioFrame* frame,
                          int32_t sample_rate,
                          int32_t no_channels,
                          int32_t no_samples,
                          uint8_t* data,
                          int32_t channel_stride) {
    if (!frame) return;

    frame->sample_rate = sample_rate;
    frame->no_channels = no_channels;
    frame->no_samples = no_samples;
    frame->timecode = NDIlib_send_timecode_synthesize;
    frame->FourCC = NDIlib_FourCC_audio_type_FLTP;  // 32-bit float planar
    frame->p_data = data;
    frame->channel_stride_in_bytes = channel_stride;
    frame->p_metadata = NULL;
    frame->timestamp = 0;
}

size_t ndi_audio_frame_size(void) {
    return sizeof(NDIBridgeAudioFrame);
}
