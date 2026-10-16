// Test-only PCM producer for TransportSilenceIntegration. It neither captures
// system audio nor checks/changes capture permission; its protocol responses
// simulate that dependency so the real Bluetooth transport can be tested alone.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
static volatile sig_atomic_t stopped;
static void stop(int signal) { (void)signal; stopped = 1; }
int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    puts("TEST_ONLY source=generated-zero-pcm permissionCheck=simulated capture=none");
    if (argc > 1 && !strcmp(argv[1], "--check-permission")) {
        puts("AUDIO_PERMISSION_ALLOWED cleanup=1 callbacks=1"); return 0;
    }
    if (argc < 4 || strcmp(argv[1], "--stream")) return 2;
    unsigned rate = 0;
    for (int i = 4; i + 1 < argc; i++) if (!strcmp(argv[i], "--sample-rate")) rate = atoi(argv[++i]);
    if (rate != 44100 && rate != 48000) return 2;
    struct sigaction action = {0}; action.sa_handler = stop; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGPIPE, &action, NULL);
    // NativeSession masks stop signals while launching the real capture helper.
    // The fixture must install handlers before unmasking them as well.
    sigset_t signals; sigemptyset(&signals); sigaddset(&signals, SIGTERM); sigaddset(&signals, SIGINT);
    sigprocmask(SIG_UNBLOCK, &signals, NULL);
    printf("PCM_CAPTURE_READY rate=%u channels=2 format=F32 interleaved=1 bytesPerFrame=8\n", rate);
    float zeros[960] = {0};
    size_t bytes = rate / 100 * 8; // 10 ms of interleaved stereo F32 silence.
    unsigned count = 0;
    while (!stopped && count++ < 6000) {
        size_t offset = 0;
        while (!stopped && offset < bytes) {
            ssize_t n = write(atoi(argv[2]), (char *)zeros + offset, bytes - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { stopped = 1; break; }
            offset += n;
        }
        struct timespec delay = {0, 10000000}; nanosleep(&delay, NULL);
    }
    puts("TEST_ONLY finished=1");
    puts("DESTROY_TAP status=0"); // Simulated dependency cleanup, no tap exists.
    return 0;
}
