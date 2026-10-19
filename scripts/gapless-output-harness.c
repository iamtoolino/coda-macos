// Compile the real bridge in this translation unit so only the test can select PCM output.
// No test hooks or alternate audio-output mode are exposed by the shipped app.
#include "../Sources/CMpv/CMpv.c"
#include <dispatch/dispatch.h>

static void wake(void *semaphore) { dispatch_semaphore_signal(semaphore); }

// Usage: output.pcm rate channels start-seconds url gain [url gain ...]
// Loads current + next like the app and supplies each following occurrence when the
// prefetched next one starts, so every transition takes the production gapless path.
// PCM output renders faster than real time, so events are handled as soon as mpv
// signals them: the following occurrence must arrive before the current one ends.
int main(int argc, char **argv) {
  if (argc < 7 || (argc - 5) % 2) return 10;
  int count = (argc - 5) / 2;
  CodaMPV *engine = coda_mpv_create();
  if (!engine) return 11;
  if (mpv_set_option_string(engine->handle, "ao", "pcm") < 0 ||
      mpv_set_option_string(engine->handle, "ao-pcm-file", argv[1]) < 0 ||
      mpv_set_option_string(engine->handle, "ao-pcm-waveheader", "no") < 0 ||
      mpv_set_option_string(engine->handle, "audio-format", "s16") < 0 ||
      mpv_set_option_string(engine->handle, "audio-samplerate", argv[2]) < 0 ||
      mpv_set_option_string(engine->handle, "audio-channels", argv[3]) < 0)
    return 12;

  const char *urls[count];
  double gains[count];
  for (int index = 0; index < count; index++) {
    urls[index] = argv[5 + 2 * index];
    gains[index] = strtod(argv[6 + 2 * index], NULL);
  }
  CodaMPVPlaylistState state = coda_mpv_load(engine, urls[0], count > 1 ? urls[1] : NULL,
                                             strtod(argv[4], NULL), false, gains[0],
                                             count > 1 ? gains[1] : 0);
  if (state.current_entry_id < 0) return 13;

  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  coda_mpv_set_wakeup_callback(engine, wake, semaphore);
  int started = 0, ended = 0;
  bool playing = false;
  // Bounded timeout; all audio is rendered offline, with no output device.
  for (int tick = 0; tick < 600 && ended < count; tick++) {
    CodaMPVEvent event;
    while (coda_mpv_next_event(engine, &event)) {
      if (event.type == CODA_MPV_EVENT_END_FILE_ERROR) return 14;
      if (event.type == CODA_MPV_EVENT_PLAYBACK_READY && !playing) {
        playing = true;
        coda_mpv_set_paused(engine, false);
      }
      if (event.type == CODA_MPV_EVENT_START_FILE && ++started >= 2 && started < count)
        coda_mpv_update_next(engine, urls[started], gains[started]);
      if (event.type == CODA_MPV_EVENT_END_FILE_EOF) ended++;
    }
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
  }
  coda_mpv_destroy(engine);
  return started == count && ended == count ? 0 : 16;
}
