// LiveDeck ↔ Blackmagic DeckLink / UltraStudio (Desktop Video) bridge.
// Uses the DeckLink SDK 12 headers (permissive Blackmagic licence, in ../sdk). The DeckLink API itself is part of the
// Blackmagic Desktop Video driver (/Library/Frameworks/DeckLinkAPI.framework) and is loaded at run time, so LiveDeck
// starts normally on Macs without Blackmagic hardware.
#ifndef CDECKLINK_H
#define CDECKLINK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when the Desktop Video driver (DeckLink API) is installed.
int cdl_api_present(void);
/// Driver API version, e.g. "12.4".
int cdl_api_version(char *buffer, int length);

int cdl_device_count(void);
/// Name and capabilities of device `index` (0-based). Returns 1 on success.
int cdl_device_info(int index, char *name, int nameLength, int *canCapture, int *canPlayback);

// ---- output ------------------------------------------------------------------------------------
/// Opens playout at the given raster and rate (interlaced = 1 for 50i/59.94i/60i). Returns NULL with a message in `error`.
void *cdl_output_open(int index, int width, int height, int rateNumerator, int rateDenominator, int interlaced,
                      int enableAudio, char *error, int errorLength);
int cdl_output_mode_name(void *output, char *buffer, int length);
/// Displays one BGRA frame (top-down). Returns 1 on success.
int cdl_output_video_bgra(void *output, const uint8_t *bgra, int width, int height, int bytesPerRow);
/// 48 kHz stereo float audio.
int cdl_output_audio(void *output, const float *left, const float *right, int frames);
void cdl_output_close(void *output);

// ---- input -------------------------------------------------------------------------------------
/// pixelFormat: 1 = 8-bit YUV 4:2:2 (UYVY / '2vuy'), 2 = 8-bit BGRA. Data is valid only during the call.
typedef void (*cdl_video_callback)(void *context, const uint8_t *data, int width, int height, int bytesPerRow, int pixelFormat);
/// 48 kHz, 32-bit integer PCM, interleaved.
typedef void (*cdl_audio_callback)(void *context, const int32_t *samples, int frames, int channels);
/// signal: 1 = receiving, 0 = no input. `message` describes the format.
typedef void (*cdl_status_callback)(void *context, int signal, const char *message);

void *cdl_input_open(int index, cdl_video_callback video, cdl_audio_callback audio, cdl_status_callback status,
                     void *context, char *error, int errorLength);
void cdl_input_close(void *input);

#ifdef __cplusplus
}
#endif
#endif
