#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Shared by the real helper and deterministic tests. No Bluetooth writes are
// retried. A visible output cannot settle a previously submitted disconnect.
typedef struct {
    bool connected;
    uint16_t handle;
    int nativeOutput; // -1: inspection failed, 0: absent, 1: alive output for the target
    unsigned disconnectGeneration;
} NativeRestoreSnapshot;

typedef struct {
    void *context;
    double (*now)(void *);
    void (*wait)(void *, double);
    NativeRestoreSnapshot (*read)(void *);
    int (*close)(void *);
    void (*record)(void *, const char *, NativeRestoreSnapshot, double, bool);
} NativeRestoreIO;

typedef enum {
    NativeRestorePreserved,
    NativeRestoreDisconnected,
    NativeRestoreUnconfirmed
} NativeRestoreResult;

static inline NativeRestoreResult NativeRestoreRunPolicy(NativeRestoreIO io, bool mayClose, uint16_t expectedHandle, bool reconfigure) {
    const double start = io.now(io.context), deadline = start + 18.0;
    double stableSince = -1, closeDeadline = deadline;
    bool submitted = false, closeArmed = false, replaced = false, first = true, fastDisqualified = false;
    NativeRestoreSnapshot initial = {0}, previous = {0};
    const char *previousPhase = NULL;
    for (;;) {
        NativeRestoreSnapshot state = io.read(io.context);
        double now = io.now(io.context);
        if (first) { initial = state; first = false; }
        replaced |= state.disconnectGeneration != initial.disconnectGeneration || state.handle != initial.handle;
        // Once an output/replacement has been observed, retain the ordinary
        // publication window. Never use the shorter grace on uncertain identity.
        fastDisqualified |= state.nativeOutput != 0 || replaced || state.handle != expectedHandle;
        const double publicationGrace = reconfigure && mayClose && !fastDisqualified ? 1.0 : 8.0;
        bool changed = state.connected != previous.connected || state.handle != previous.handle ||
            state.nativeOutput != previous.nativeOutput || state.disconnectGeneration != previous.disconnectGeneration;
        if (changed || state.nativeOutput != 1) stableSince = -1;

        const char *phase;
        NativeRestoreResult result = NativeRestoreUnconfirmed;
        bool finished = false;
        if (!state.connected) {
            phase = "disconnected"; result = NativeRestoreDisconnected; finished = true;
        } else if (state.nativeOutput < 0) {
            phase = "inspection-error"; finished = true;
        } else if (now >= deadline || (submitted && now >= closeDeadline)) {
            phase = submitted ? "disconnect-timeout" : "publication-timeout"; finished = true;
        } else if (state.nativeOutput == 1 && (!submitted || state.disconnectGeneration != initial.disconnectGeneration)) {
            // Require consecutive observations of the same connection and output.
            if (stableSince < 0) stableSince = now;
            phase = "wait-stability";
            if (now - stableSince >= 0.3) {
                phase = "preserved"; result = NativeRestorePreserved; finished = true;
            }
            closeArmed = false;
        } else if (submitted) {
            // Only a disconnect callback or an observed disconnected state can
            // settle closeConnection. A handle change alone is not sufficient.
            phase = "wait-disconnect";
        } else if (now - start < publicationGrace) {
            phase = "wait-publication";
        } else if (mayClose && !replaced && state.handle == expectedHandle) {
            // Take another complete snapshot on the next turn before writing.
            phase = closeArmed ? "close" : "check-before-close";
            if (closeArmed) {
                submitted = true;
                // Early close must not shorten the previous overall settlement
                // window: a late callback can still arrive until the same 18 s.
                closeDeadline = reconfigure ? deadline : now + 10.0;
                if (io.close(io.context) != 0) { phase = "close-error"; finished = true; }
            }
            closeArmed = true;
        } else {
            phase = "publication-timeout"; finished = true;
        }
        if (phase != previousPhase || changed || finished)
            io.record(io.context, phase, state, now - start, submitted);
        previousPhase = phase; previous = state;
        if (finished) return result;
        io.wait(io.context, 0.05);
    }
}

// Normal stop/quit/failure restoration retains the historical 8-second grace.
static inline NativeRestoreResult NativeRestoreRun(NativeRestoreIO io, bool mayClose, uint16_t expectedHandle) {
    return NativeRestoreRunPolicy(io, mayClose, expectedHandle, false);
}
