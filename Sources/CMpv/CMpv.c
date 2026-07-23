#include "CMpv.h"

#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
  PROPERTY_TIME_POSITION = 1,
  PROPERTY_DURATION,
  PROPERTY_PAUSE,
  PROPERTY_BUFFERING,
  PROPERTY_CACHE_DURATION,
  PROPERTY_IDLE,
};

struct CodaMPV {
  mpv_handle *handle;
  CodaMPVEvent snapshot;
  double pending_resume_position;
  bool pending_resume_should_play;
  bool pending_resume_seek_issued;
  bool pending_resume_seek_started;
};

static void observe(CodaMPV *engine, uint64_t identifier, const char *name, mpv_format format) {
  mpv_observe_property(engine->handle, identifier, name, format);
}

static void command(CodaMPV *engine, const char *arguments[]) {
  mpv_command_async(engine->handle, 0, arguments);
}

static void set_flag(CodaMPV *engine, const char *name, bool value) {
  int flag = value ? 1 : 0;
  mpv_set_property_async(engine->handle, 0, name, MPV_FORMAT_FLAG, &flag);
}

static void set_double(CodaMPV *engine, const char *name, double value) {
  mpv_set_property_async(engine->handle, 0, name, MPV_FORMAT_DOUBLE, &value);
}

CodaMPV *coda_mpv_create(void) {
  CodaMPV *engine = calloc(1, sizeof(CodaMPV));
  if (!engine)
    return NULL;

  engine->handle = mpv_create();
  if (!engine->handle) {
    free(engine);
    return NULL;
  }

  const char *options[][2] = {
    {"config", "no"},
    {"load-scripts", "no"},
    {"video", "no"},
    {"audio-display", "no"},
    {"terminal", "no"},
    {"input-default-bindings", "no"},
    {"input-vo-keyboard", "no"},
    {"ytdl", "no"},
    {"idle", "yes"},
    {"ao", "coreaudio"},
    {"gapless-audio", "weak"},
    {"prefetch-playlist", "yes"},
    {"network-timeout", "10"},
    {"stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_at_eof=1,reconnect_delay_max=5"},
  };
  for (size_t index = 0; index < sizeof(options) / sizeof(options[0]); index++)
    mpv_set_option_string(engine->handle, options[index][0], options[index][1]);

  if (mpv_initialize(engine->handle) < 0) {
    mpv_terminate_destroy(engine->handle);
    free(engine);
    return NULL;
  }

  observe(engine, PROPERTY_TIME_POSITION, "time-pos", MPV_FORMAT_DOUBLE);
  observe(engine, PROPERTY_DURATION, "duration", MPV_FORMAT_DOUBLE);
  observe(engine, PROPERTY_PAUSE, "pause", MPV_FORMAT_FLAG);
  observe(engine, PROPERTY_BUFFERING, "paused-for-cache", MPV_FORMAT_FLAG);
  observe(engine, PROPERTY_CACHE_DURATION, "demuxer-cache-duration", MPV_FORMAT_DOUBLE);
  observe(engine, PROPERTY_IDLE, "idle-active", MPV_FORMAT_FLAG);
  return engine;
}

void coda_mpv_destroy(CodaMPV *engine) {
  if (!engine)
    return;
  mpv_set_wakeup_callback(engine->handle, NULL, NULL);
  mpv_terminate_destroy(engine->handle);
  free(engine);
}

void coda_mpv_set_wakeup_callback(
  CodaMPV *engine,
  CodaMPVWakeupCallback callback,
  void *context
) {
  if (engine)
    mpv_set_wakeup_callback(engine->handle, callback, context);
}

bool coda_mpv_next_event(CodaMPV *engine, CodaMPVEvent *output) {
  if (!engine || !output)
    return false;

  mpv_event *event = mpv_wait_event(engine->handle, 0);
  if (!event || event->event_id == MPV_EVENT_NONE)
    return false;

  *output = engine->snapshot;
  switch (event->event_id) {
  case MPV_EVENT_START_FILE: {
    mpv_event_start_file *start = event->data;
    output->playlist_entry_id = start ? start->playlist_entry_id : 0;
    output->type = CODA_MPV_EVENT_START_FILE;
    return true;
  }
  case MPV_EVENT_END_FILE: {
    mpv_event_end_file *end = event->data;
    output->playlist_entry_id = end ? end->playlist_entry_id : 0;
    output->type = end && end->reason == MPV_END_FILE_REASON_ERROR
      ? CODA_MPV_EVENT_END_FILE_ERROR
      : CODA_MPV_EVENT_END_FILE_EOF;
    return true;
  }
  case MPV_EVENT_FILE_LOADED:
    if (engine->pending_resume_position > 0) {
      char seconds[64];
      snprintf(seconds, sizeof(seconds), "%.9f", engine->pending_resume_position);
      const char *seek[] = {"seek", seconds, "absolute+exact", NULL};
      engine->pending_resume_seek_issued = true;
      command(engine, seek);
    }
    return true;
  case MPV_EVENT_SEEK:
    if (engine->pending_resume_position > 0 && engine->pending_resume_seek_issued)
      engine->pending_resume_seek_started = true;
    return true;
  case MPV_EVENT_PLAYBACK_RESTART:
    if (
      engine->pending_resume_position > 0 &&
      engine->pending_resume_seek_issued &&
      engine->pending_resume_seek_started
    ) {
      bool should_play = engine->pending_resume_should_play;
      engine->pending_resume_position = 0;
      engine->pending_resume_should_play = false;
      engine->pending_resume_seek_issued = false;
      engine->pending_resume_seek_started = false;
      if (should_play)
        set_flag(engine, "pause", false);
    }
    return true;
  case MPV_EVENT_SHUTDOWN:
    output->type = CODA_MPV_EVENT_SHUTDOWN;
    return true;
  case MPV_EVENT_PROPERTY_CHANGE: {
    mpv_event_property *property = event->data;
    if (!property || !property->data)
      return true;
    switch (event->reply_userdata) {
    case PROPERTY_TIME_POSITION:
      engine->snapshot.position = *(double *)property->data;
      break;
    case PROPERTY_DURATION:
      engine->snapshot.duration = *(double *)property->data;
      break;
    case PROPERTY_PAUSE:
      engine->snapshot.is_playing = !*(int *)property->data;
      break;
    case PROPERTY_BUFFERING:
      engine->snapshot.is_buffering = *(int *)property->data;
      break;
    case PROPERTY_CACHE_DURATION:
      engine->snapshot.buffered_until = engine->snapshot.position + *(double *)property->data;
      break;
    case PROPERTY_IDLE:
      engine->snapshot.is_idle = *(int *)property->data;
      *output = engine->snapshot;
      output->type = CODA_MPV_EVENT_IDLE_CHANGED;
      return true;
    default:
      return true;
    }
    *output = engine->snapshot;
    output->type = CODA_MPV_EVENT_SNAPSHOT;
    return true;
  }
  default:
    return true;
  }
}

void coda_mpv_load(
  CodaMPV *engine,
  const char *current_url,
  const char *next_url,
  double position,
  bool autoplay
) {
  if (!engine || !current_url)
    return;
  // A cold `start=<position>` can stall before mpv begins reading a remote
  // stream. Load normally while paused, then use the fast in-file seek path
  // once mpv reports the file ready. Playback resumes only after that seek
  // completes, preventing both startup audio and pre-seek artifacts.
  engine->pending_resume_position = position > 0 ? position : 0;
  engine->pending_resume_should_play = autoplay && position > 0;
  engine->pending_resume_seek_issued = false;
  engine->pending_resume_seek_started = false;
  set_flag(engine, "pause", !autoplay || position > 0);
  const char *load[] = {"loadfile", current_url, "replace", NULL};
  command(engine, load);
  if (next_url) {
    const char *append[] = {"loadfile", next_url, "append", NULL};
    command(engine, append);
  }
}

void coda_mpv_update_next(CodaMPV *engine, const char *next_url) {
  if (!engine)
    return;
  const char *clear[] = {"playlist-clear", NULL};
  command(engine, clear);
  if (next_url) {
    const char *insert[] = {"loadfile", next_url, "insert-next", NULL};
    command(engine, insert);
  }
}

void coda_mpv_set_paused(CodaMPV *engine, bool paused) {
  if (engine) {
    if (engine->pending_resume_position > 0) {
      engine->pending_resume_should_play = !paused;
      if (!paused)
        return;
    }
    set_flag(engine, "pause", paused);
  }
}

void coda_mpv_seek(CodaMPV *engine, double position) {
  if (engine) {
    engine->pending_resume_position = 0;
    engine->pending_resume_should_play = false;
    engine->pending_resume_seek_issued = false;
    engine->pending_resume_seek_started = false;
    set_double(engine, "time-pos", position);
  }
}

void coda_mpv_stop(CodaMPV *engine) {
  if (!engine)
    return;
  engine->pending_resume_position = 0;
  engine->pending_resume_should_play = false;
  engine->pending_resume_seek_issued = false;
  engine->pending_resume_seek_started = false;
  const char *stop[] = {"stop", NULL};
  command(engine, stop);
}

void coda_mpv_set_volume(CodaMPV *engine, double volume) {
  if (engine)
    set_double(engine, "volume", volume * 100.0);
}

void coda_mpv_set_muted(CodaMPV *engine, bool muted) {
  if (engine)
    set_flag(engine, "mute", muted);
}
