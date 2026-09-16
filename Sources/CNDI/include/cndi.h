// Thin C bridge between LiveDeck (Swift) and the NDI® runtime (libndi.dylib, NDI SDK v6 for Apple).
// The runtime is loaded with dlopen at launch, so LiveDeck still starts when NDI is not present.
// NDI® is a registered trademark of Vizrt NDI AB — https://ndi.video
#ifndef CNDI_H
#define CNDI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads libndi from `path` and initialises it. Returns 1 on success.
int cndi_load(const char *path);
int cndi_is_loaded(void);
const char *cndi_version(void);
/// Last loading error (empty string when none).
const char *cndi_last_error(void);

// ---- sending -------------------------------------------------------------------------------------
void *cndi_send_create(const char *name, const char *groups);
void cndi_send_destroy(void *sender);
/// BGRA (or BGRX when `has_alpha` is 0) top-down frame. `interlaced` 1 = woven fields (top field first).
void cndi_send_video_bgra(void *sender, int width, int height, int stride, const uint8_t *data,
                          int fps_n, int fps_d, int interlaced, int has_alpha);
/// Planar 32-bit float audio: `planar` holds `channels × samples` values (channel 0 first).
void cndi_send_audio_planar(void *sender, int sample_rate, int channels, int samples, const float *planar);
int cndi_send_connections(void *sender);
/// Returns 1 when tally changed or was read; fills program/preview (0/1).
int cndi_send_tally(void *sender, int *on_program, int *on_preview);

// ---- finding sources -----------------------------------------------------------------------------
void *cndi_find_create(void);
void cndi_find_destroy(void *finder);
/// Writes the current source names, separated by '\n', into `buffer`. Returns the number of sources.
int cndi_find_sources(void *finder, char *buffer, int buffer_len);

// ---- receiving -----------------------------------------------------------------------------------
typedef struct cndi_video {
    int width, height, stride, fps_n, fps_d, interlaced, has_alpha;
    const uint8_t *data;       // BGRA/BGRX, top-down
    void *internal;
} cndi_video;

typedef struct cndi_audio {
    int sample_rate, channels, samples, channel_stride;
    const float *data;         // planar float
    void *internal;
} cndi_audio;

void *cndi_recv_create(const char *source_name, const char *receiver_name, int low_bandwidth);
void cndi_recv_destroy(void *receiver);
/// 1 = video filled, 2 = audio filled, 0 = nothing within the timeout, -1 = source lost / error.
int cndi_recv_capture(void *receiver, int timeout_ms, cndi_video *video, cndi_audio *audio);
void cndi_recv_free_video(void *receiver, cndi_video *video);
void cndi_recv_free_audio(void *receiver, cndi_audio *audio);
void cndi_recv_set_tally(void *receiver, int on_program, int on_preview);

#ifdef __cplusplus
}
#endif
#endif
