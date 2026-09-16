// See include/cndi.h. Uses the official NDI SDK v6 headers (MIT-licensed, in ndi/) for exact struct layouts
// and looks each exported function up by name, so any NDI 5/6 runtime works.
#include "include/cndi.h"
#include "ndi/Processing.NDI.Lib.h"
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static struct {
    void *handle;
    int ready;
    char error[256];
    __typeof__(NDIlib_initialize) *initialize;
    __typeof__(NDIlib_version) *version;
    __typeof__(NDIlib_send_create) *send_create;
    __typeof__(NDIlib_send_destroy) *send_destroy;
    __typeof__(NDIlib_send_send_video_v2) *send_video_v2;
    __typeof__(NDIlib_send_send_audio_v3) *send_audio_v3;
    __typeof__(NDIlib_send_get_tally) *send_get_tally;
    __typeof__(NDIlib_send_get_no_connections) *send_get_no_connections;
    __typeof__(NDIlib_find_create_v2) *find_create_v2;
    __typeof__(NDIlib_find_destroy) *find_destroy;
    __typeof__(NDIlib_find_get_current_sources) *find_get_current_sources;
    __typeof__(NDIlib_recv_create_v3) *recv_create_v3;
    __typeof__(NDIlib_recv_destroy) *recv_destroy;
    __typeof__(NDIlib_recv_capture_v3) *recv_capture_v3;
    __typeof__(NDIlib_recv_free_video_v2) *recv_free_video_v2;
    __typeof__(NDIlib_recv_free_audio_v3) *recv_free_audio_v3;
    __typeof__(NDIlib_recv_set_tally) *recv_set_tally;
} ndi;

#define NDI_SYM(field, name) do { ndi.field = dlsym(ndi.handle, name); if (!ndi.field) { snprintf(ndi.error, sizeof ndi.error, "missing symbol %s", name); goto fail; } } while (0)

int cndi_load(const char *path) {
    if (ndi.ready) return 1;
    ndi.error[0] = 0;
    if (!path) { snprintf(ndi.error, sizeof ndi.error, "no path"); return 0; }
    ndi.handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!ndi.handle) { const char *e = dlerror(); snprintf(ndi.error, sizeof ndi.error, "%s", e ? e : "dlopen failed"); return 0; }
    NDI_SYM(initialize, "NDIlib_initialize");
    NDI_SYM(version, "NDIlib_version");
    NDI_SYM(send_create, "NDIlib_send_create");
    NDI_SYM(send_destroy, "NDIlib_send_destroy");
    NDI_SYM(send_video_v2, "NDIlib_send_send_video_v2");
    NDI_SYM(send_audio_v3, "NDIlib_send_send_audio_v3");
    NDI_SYM(send_get_tally, "NDIlib_send_get_tally");
    NDI_SYM(send_get_no_connections, "NDIlib_send_get_no_connections");
    NDI_SYM(find_create_v2, "NDIlib_find_create_v2");
    NDI_SYM(find_destroy, "NDIlib_find_destroy");
    NDI_SYM(find_get_current_sources, "NDIlib_find_get_current_sources");
    NDI_SYM(recv_create_v3, "NDIlib_recv_create_v3");
    NDI_SYM(recv_destroy, "NDIlib_recv_destroy");
    NDI_SYM(recv_capture_v3, "NDIlib_recv_capture_v3");
    NDI_SYM(recv_free_video_v2, "NDIlib_recv_free_video_v2");
    NDI_SYM(recv_free_audio_v3, "NDIlib_recv_free_audio_v3");
    NDI_SYM(recv_set_tally, "NDIlib_recv_set_tally");
    if (!ndi.initialize()) { snprintf(ndi.error, sizeof ndi.error, "NDI is not supported on this CPU"); goto fail; }
    ndi.ready = 1;
    return 1;
fail:
    dlclose(ndi.handle);
    ndi.handle = NULL;
    return 0;
}

int cndi_is_loaded(void) { return ndi.ready; }
const char *cndi_version(void) { return ndi.ready ? ndi.version() : ""; }
const char *cndi_last_error(void) { return ndi.error; }

// ---- sending

void *cndi_send_create(const char *name, const char *groups) {
    if (!ndi.ready) return NULL;
    NDIlib_send_create_t c;
    memset(&c, 0, sizeof c);
    c.p_ndi_name = name;
    c.p_groups = (groups && groups[0]) ? groups : NULL;
    c.clock_video = false;   // LiveDeck paces frames itself
    c.clock_audio = false;
    return ndi.send_create(&c);
}

void cndi_send_destroy(void *sender) { if (ndi.ready && sender) ndi.send_destroy((NDIlib_send_instance_t)sender); }

void cndi_send_video_bgra(void *sender, int width, int height, int stride, const uint8_t *data,
                          int fps_n, int fps_d, int interlaced, int has_alpha) {
    if (!ndi.ready || !sender || !data) return;
    NDIlib_video_frame_v2_t f;
    memset(&f, 0, sizeof f);
    f.xres = width; f.yres = height;
    f.FourCC = has_alpha ? NDIlib_FourCC_video_type_BGRA : NDIlib_FourCC_video_type_BGRX;
    f.frame_rate_N = fps_n; f.frame_rate_D = fps_d;
    f.picture_aspect_ratio = 0;   // square pixels
    f.frame_format_type = interlaced ? NDIlib_frame_format_type_interleaved : NDIlib_frame_format_type_progressive;
    f.timecode = NDIlib_send_timecode_synthesize;
    f.p_data = (uint8_t *)data;
    f.line_stride_in_bytes = stride;
    f.p_metadata = NULL;
    ndi.send_video_v2((NDIlib_send_instance_t)sender, &f);
}

void cndi_send_audio_planar(void *sender, int sample_rate, int channels, int samples, const float *planar) {
    if (!ndi.ready || !sender || !planar || samples <= 0) return;
    NDIlib_audio_frame_v3_t a;
    memset(&a, 0, sizeof a);
    a.sample_rate = sample_rate; a.no_channels = channels; a.no_samples = samples;
    a.timecode = NDIlib_send_timecode_synthesize;
    a.FourCC = NDIlib_FourCC_audio_type_FLTP;
    a.p_data = (uint8_t *)planar;
    a.channel_stride_in_bytes = samples * (int)sizeof(float);
    a.p_metadata = NULL;
    ndi.send_audio_v3((NDIlib_send_instance_t)sender, &a);
}

int cndi_send_connections(void *sender) {
    if (!ndi.ready || !sender) return 0;
    return ndi.send_get_no_connections((NDIlib_send_instance_t)sender, 0);
}

int cndi_send_tally(void *sender, int *on_program, int *on_preview) {
    if (!ndi.ready || !sender) return 0;
    NDIlib_tally_t t;
    memset(&t, 0, sizeof t);
    ndi.send_get_tally((NDIlib_send_instance_t)sender, &t, 0);
    if (on_program) *on_program = t.on_program ? 1 : 0;
    if (on_preview) *on_preview = t.on_preview ? 1 : 0;
    return 1;
}

// ---- finding

void *cndi_find_create(void) {
    if (!ndi.ready) return NULL;
    NDIlib_find_create_t c;
    memset(&c, 0, sizeof c);
    c.show_local_sources = true;
    return ndi.find_create_v2(&c);
}

void cndi_find_destroy(void *finder) { if (ndi.ready && finder) ndi.find_destroy((NDIlib_find_instance_t)finder); }

int cndi_find_sources(void *finder, char *buffer, int buffer_len) {
    if (!ndi.ready || !finder || !buffer || buffer_len <= 0) return 0;
    uint32_t n = 0;
    const NDIlib_source_t *s = ndi.find_get_current_sources((NDIlib_find_instance_t)finder, &n);
    int used = 0;
    buffer[0] = 0;
    for (uint32_t i = 0; i < n && s; i++) {
        const char *name = s[i].p_ndi_name ? s[i].p_ndi_name : "";
        int len = (int)strlen(name);
        if (used + len + 2 >= buffer_len) break;
        memcpy(buffer + used, name, (size_t)len);
        used += len;
        buffer[used++] = '\n';
        buffer[used] = 0;
    }
    return (int)n;
}

// ---- receiving

void *cndi_recv_create(const char *source_name, const char *receiver_name, int low_bandwidth) {
    if (!ndi.ready || !source_name) return NULL;
    NDIlib_recv_create_v3_t c;
    memset(&c, 0, sizeof c);
    c.source_to_connect_to.p_ndi_name = source_name;
    c.source_to_connect_to.p_url_address = NULL;
    c.color_format = NDIlib_recv_color_format_BGRX_BGRA;
    c.bandwidth = low_bandwidth ? NDIlib_recv_bandwidth_lowest : NDIlib_recv_bandwidth_highest;
    c.allow_video_fields = false;   // progressive frames are easier to composite
    c.p_ndi_recv_name = receiver_name;
    return ndi.recv_create_v3(&c);
}

void cndi_recv_destroy(void *receiver) { if (ndi.ready && receiver) ndi.recv_destroy((NDIlib_recv_instance_t)receiver); }

int cndi_recv_capture(void *receiver, int timeout_ms, cndi_video *video, cndi_audio *audio) {
    if (!ndi.ready || !receiver) return -1;
    NDIlib_video_frame_v2_t *v = calloc(1, sizeof(NDIlib_video_frame_v2_t));
    NDIlib_audio_frame_v3_t *a = calloc(1, sizeof(NDIlib_audio_frame_v3_t));
    if (!v || !a) { free(v); free(a); return 0; }
    NDIlib_frame_type_e type = ndi.recv_capture_v3((NDIlib_recv_instance_t)receiver, v, a, NULL, (uint32_t)(timeout_ms < 0 ? 0 : timeout_ms));
    if (type == NDIlib_frame_type_video && video) {
        video->width = v->xres; video->height = v->yres;
        video->stride = v->line_stride_in_bytes ? v->line_stride_in_bytes : v->xres * 4;
        video->fps_n = v->frame_rate_N; video->fps_d = v->frame_rate_D;
        video->interlaced = v->frame_format_type == NDIlib_frame_format_type_progressive ? 0 : 1;
        video->has_alpha = v->FourCC == NDIlib_FourCC_video_type_BGRA ? 1 : 0;
        video->data = v->p_data;
        video->internal = v;
        free(a);
        return 1;
    }
    if (type == NDIlib_frame_type_audio && audio) {
        audio->sample_rate = a->sample_rate; audio->channels = a->no_channels; audio->samples = a->no_samples;
        audio->channel_stride = a->channel_stride_in_bytes;
        audio->data = (const float *)a->p_data;
        audio->internal = a;
        free(v);
        return 2;
    }
    free(v); free(a);
    if (type == NDIlib_frame_type_error) return -1;
    return 0;
}

void cndi_recv_free_video(void *receiver, cndi_video *video) {
    if (!ndi.ready || !receiver || !video || !video->internal) return;
    ndi.recv_free_video_v2((NDIlib_recv_instance_t)receiver, (NDIlib_video_frame_v2_t *)video->internal);
    free(video->internal);
    video->internal = NULL; video->data = NULL;
}

void cndi_recv_free_audio(void *receiver, cndi_audio *audio) {
    if (!ndi.ready || !receiver || !audio || !audio->internal) return;
    ndi.recv_free_audio_v3((NDIlib_recv_instance_t)receiver, (NDIlib_audio_frame_v3_t *)audio->internal);
    free(audio->internal);
    audio->internal = NULL; audio->data = NULL;
}

void cndi_recv_set_tally(void *receiver, int on_program, int on_preview) {
    if (!ndi.ready || !receiver) return;
    NDIlib_tally_t t;
    memset(&t, 0, sizeof t);
    t.on_program = on_program != 0;
    t.on_preview = on_preview != 0;
    ndi.recv_set_tally((NDIlib_recv_instance_t)receiver, &t);
}

