// Compile the real bridge in this translation unit so only the test can select PCM output.
// No test hooks or alternate audio-output mode are exposed by the shipped app.
#include "../Sources/CMpv/CMpv.c"
#include <math.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 6) return 10;
  CodaMPV *engine = coda_mpv_create();
  if (!engine) return 11;
  if (mpv_set_option_string(engine->handle, "ao", "pcm") < 0 ||
      mpv_set_option_string(engine->handle, "ao-pcm-file", argv[2]) < 0 ||
      mpv_set_option_string(engine->handle, "audio-format", "s16") < 0 ||
      mpv_set_option_string(engine->handle, "audio-channels", "mono") < 0 ||
      mpv_set_option_string(engine->handle, "audio-samplerate", "48000") < 0)
    return 12;

  double current = strtod(argv[3], NULL);
  double next = strtod(argv[4], NULL);
  int scenario = atoi(argv[5]); // 1: same-URL next update, 2: turn Off before unpausing.
  CodaMPVPlaylistState state = coda_mpv_load(engine, argv[1], argv[1], 0, false,
                                          current, next);
  if (state.current_entry_id < 0 || state.next_entry_id < 0) return 13;
  if (scenario == 1) coda_mpv_update_next(engine, argv[1], -9);

  int ended = 0;
  bool started = false;
  // Bounded timeout; all audio is rendered offline, with no output device or server.
  for (int tick = 0; tick < 10000 && ended < 2; tick++) {
    CodaMPVEvent event;
    while (coda_mpv_next_event(engine, &event)) {
      if (event.type == CODA_MPV_EVENT_END_FILE_ERROR) return 14;
      if (event.type == CODA_MPV_EVENT_PLAYBACK_READY && !started) {
        double actual = NAN;
        if (mpv_get_property(engine->handle, "volume-gain", MPV_FORMAT_DOUBLE, &actual) < 0 ||
            fabs(actual - current) > 0.00001) {
          fprintf(stderr, "Initial gain %.6f, expected %.6f\n", actual, current);
          coda_mpv_destroy(engine);
          return 15;
        }
        if (scenario == 2) {
          coda_mpv_set_replay_gain(engine, 0);
          coda_mpv_update_next(engine, argv[1], 0);
        }
        started = true;
        coda_mpv_set_paused(engine, false);
      }
      if (event.type == CODA_MPV_EVENT_END_FILE_EOF) ended++;
    }
    usleep(1000);
  }
  coda_mpv_destroy(engine);
  return ended == 2 ? 0 : 16;
}
