#ifndef CODA_MPV_H
#define CODA_MPV_H

#include <stdbool.h>
#include <stdint.h>

typedef struct CodaMPV CodaMPV;

typedef enum CodaMPVEventType {
  CODA_MPV_EVENT_NONE = 0,
  CODA_MPV_EVENT_SNAPSHOT = 1,
  CODA_MPV_EVENT_START_FILE = 2,
  CODA_MPV_EVENT_END_FILE_EOF = 3,
  CODA_MPV_EVENT_END_FILE_ERROR = 4,
  CODA_MPV_EVENT_IDLE_CHANGED = 5,
  CODA_MPV_EVENT_SHUTDOWN = 6,
} CodaMPVEventType;

typedef struct CodaMPVEvent {
  CodaMPVEventType type;
  int64_t playlist_entry_id;
  double position;
  double duration;
  double buffered_until;
  bool is_playing;
  bool is_buffering;
  bool is_idle;
} CodaMPVEvent;

typedef void (*CodaMPVWakeupCallback)(void *context);

CodaMPV *coda_mpv_create(void);
void coda_mpv_destroy(CodaMPV *engine);
void coda_mpv_set_wakeup_callback(
  CodaMPV *engine,
  CodaMPVWakeupCallback callback,
  void *context
);
bool coda_mpv_next_event(CodaMPV *engine, CodaMPVEvent *event);

void coda_mpv_load(
  CodaMPV *engine,
  const char *current_url,
  const char *next_url,
  double position,
  bool autoplay
);
void coda_mpv_update_next(CodaMPV *engine, const char *next_url);
void coda_mpv_set_paused(CodaMPV *engine, bool paused);
void coda_mpv_seek(CodaMPV *engine, double position);
void coda_mpv_stop(CodaMPV *engine);
void coda_mpv_set_volume(CodaMPV *engine, double volume);
void coda_mpv_set_muted(CodaMPV *engine, bool muted);

#endif
