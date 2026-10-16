#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../../Native/Transport/NativeRestore.h"

typedef struct { double at; NativeRestoreSnapshot state; } Step;
typedef struct {
    const Step *steps;
    unsigned count, closes;
    double time, closedAt;
    int closeStatus;
    bool disconnectAfterClose;
    char finalPhase[64];
} Fixture;
static double Now(void *raw) { return ((Fixture *)raw)->time; }
static void Wait(void *raw, double seconds) { ((Fixture *)raw)->time += seconds; }
static NativeRestoreSnapshot Read(void *raw) {
    Fixture *f = raw;
    NativeRestoreSnapshot state = f->steps[0].state;
    for (unsigned i = 1; i < f->count && f->steps[i].at <= f->time; ++i) state = f->steps[i].state;
    if (f->disconnectAfterClose && f->closes && f->time - f->closedAt >= 2.0) state = (NativeRestoreSnapshot){false, 0xFFFF, 0, 1};
    return state;
}
static int Close(void *raw) {
    Fixture *f = raw; f->closes++; f->closedAt = f->time;
    assert(f->closes == 1); // The runner must never replay a disconnect request.
    return f->closeStatus;
}
static void Record(void *raw, const char *phase, NativeRestoreSnapshot state, double elapsed, bool submitted) {
    Fixture *f = raw;
    (void)state; (void)elapsed; (void)submitted;
    snprintf(f->finalPhase, sizeof(f->finalPhase), "%s", phase);
}
static Fixture Run(const Step *steps, unsigned count, bool allowClose, uint16_t expected, int closeStatus, NativeRestoreResult expectedResult) {
    Fixture f = {.steps=steps, .count=count, .closedAt=-1, .closeStatus=closeStatus};
    NativeRestoreResult result = NativeRestoreRun((NativeRestoreIO){&f, Now, Wait, Read, Close, Record}, allowClose, expected);
    assert(result == expectedResult);
    assert(f.time <= 18.06);
    return f;
}
#define RUN(steps, allow, expected, status, result) Run(steps, sizeof(steps)/sizeof(*steps), allow, expected, status, result)
#define STATE(native) {true, 0, native, 0}

int main(void) {
    // Model the observed 0.1.19 ordering: the target output is absent at entry,
    // then is selectable by the later route-restoration check. The exact moment
    // of publication was not logged; 5.2 s exercises this delayed case.
    // The shared production runner must preserve it without issuing close.
    Step delayed[] = {{0, STATE(0)}, {5.2, STATE(1)}};
    Fixture f = RUN(delayed, true, 0, 0, NativeRestorePreserved);
    assert(f.closes == 0 && f.time >= 5.5 && f.time < 5.7);

    Step ready[] = {{0, STATE(1)}};
    f = RUN(ready, true, 0, 0, NativeRestorePreserved);
    assert(f.closes == 0 && f.time >= 0.3);

    // An output appearing after a submitted close is not proof that close has
    // completed. Keep waiting and fail, even if that output remains visible.
    Step pending[] = {{0, STATE(0)}, {9, STATE(1)}};
    f = RUN(pending, true, 0, 0, NativeRestoreUnconfirmed);
    assert(f.closes == 1 && f.closedAt >= 8 && !strcmp(f.finalPhase, "disconnect-timeout"));
    Step ambiguousHandle[] = {{0, STATE(0)}, {9, {true, 42, 1, 0}}};
    f = RUN(ambiguousHandle, true, 0, 0, NativeRestoreUnconfirmed); assert(f.closes == 1);

    // A disconnect callback settles the original connection even when handle 0
    // is reused and polling never samples the brief disconnected interval.
    Step reconnected[] = {{0, STATE(0)}, {9, {true, 0, 1, 1}}};
    f = RUN(reconnected, true, 0, 0, NativeRestorePreserved);
    assert(f.closes == 1 && f.time >= 9.3);

    Step disconnected[] = {{0, STATE(0)}, {9, {false, 0xFFFF, 0, 0}}};
    f = RUN(disconnected, true, 0, 0, NativeRestoreDisconnected);
    assert(f.closes == 1);
    Step alreadyDisconnected[] = {{0, {false, 0xFFFF, 0, 0}}};
    f = RUN(alreadyDisconnected, true, 0, 0, NativeRestoreDisconnected); assert(f.closes == 0);

    // A different or already-replaced connection is never ours to disconnect.
    Step wrong[] = {{0, {true, 42, 0, 0}}};
    f = RUN(wrong, true, 0, 0, NativeRestoreUnconfirmed); assert(f.closes == 0);
    Step changed[] = {{0, STATE(0)}, {1, {true, 0, 0, 1}}};
    f = RUN(changed, true, 0, 0, NativeRestoreUnconfirmed); assert(f.closes == 0);
    Step newReady[] = {{0, STATE(0)}, {1, {true, 42, 0, 1}}, {2, {true, 42, 1, 1}}};
    f = RUN(newReady, true, 0, 0, NativeRestorePreserved); assert(f.closes == 0);

    Step absent[] = {{0, STATE(0)}};
    f = RUN(absent, false, 0, 0, NativeRestoreUnconfirmed); assert(f.closes == 0 && f.time < 8.1);
    f = RUN(absent, true, 0, 3, NativeRestoreUnconfirmed); assert(f.closes == 1 && !strcmp(f.finalPhase, "close-error"));
    Step unknown[] = {{0, STATE(-1)}};
    f = RUN(unknown, true, 0, 0, NativeRestoreUnconfirmed); assert(f.closes == 0);
    Step lostInspection[] = {{0, STATE(0)}, {9, STATE(-1)}};
    f = RUN(lostInspection, true, 0, 0, NativeRestoreUnconfirmed); assert(f.closes == 1);

    // A brief publication is insufficient; stability restarts on disappearance
    // and on connection-generation changes, without resetting the total deadline.
    Step flicker[] = {{0, STATE(1)}, {.2, STATE(0)}, {.25, STATE(1)}, {.45, {true, 0, 1, 1}}};
    f = RUN(flicker, true, 0, 0, NativeRestorePreserved); assert(f.closes == 0 && f.time >= .75);
    Step tooLate[] = {{0, STATE(0)}, {17.9, {true, 0, 1, 1}}};
    f = RUN(tooLate, true, 0, 0, NativeRestoreUnconfirmed); assert(f.closes == 1);
    Step lateButStable[] = {{0, STATE(0)}, {17, {true, 0, 1, 1}}};
    f = RUN(lateButStable, true, 0, 0, NativeRestorePreserved); assert(f.closes == 1 && f.time < 18);

    // The extra pre-write snapshot catches a publication at the boundary.
    Step beforeWrite[] = {{0, STATE(0)}, {8.03, STATE(1)}};
    f = RUN(beforeWrite, true, 0, 0, NativeRestorePreserved); assert(f.closes == 0);
    // Same production runner: 2-second close callback latency, no native output.
    // Reconfiguration saves publication grace only; physical close remains required.
    Fixture slow = {.steps=absent, .count=1, .closedAt=-1, .disconnectAfterClose=true};
    Fixture fast = slow;
    NativeRestoreIO slowIO = {&slow, Now, Wait, Read, Close, Record};
    NativeRestoreIO fastIO = {&fast, Now, Wait, Read, Close, Record};
    assert(NativeRestoreRun(slowIO, true, 0) == NativeRestoreDisconnected);
    assert(NativeRestoreRunPolicy(fastIO, true, 0, true) == NativeRestoreDisconnected);
    assert(slow.closes == 1 && fast.closes == 1 && fast.closedAt >= 1 && fast.closedAt < 1.1);
    assert(slow.time - fast.time > 6.8 && slow.time - fast.time < 7.2);
    printf("RECONFIGURE_TIMING simulated ordinary=%.3f reconfigure=%.3f saved=%.3f closeLatency=2.0\n", slow.time, fast.time, slow.time-fast.time);

    Step fastEarly[] = {{0, STATE(0)}, {.5, STATE(1)}};
    Step fastBoundary[] = {{0, STATE(0)}, {1.03, STATE(1)}};
    Step fastReplaced[] = {{0, STATE(0)}, {.5, {true, 42, 0, 1}}, {5.2, {true, 42, 1, 1}}};
    Step fastFlicker[] = {{0, STATE(0)}, {.3, STATE(1)}, {.4, STATE(0)}, {5.2, STATE(1)}};
    const Step *preserve[] = {fastEarly, fastBoundary, fastReplaced, fastFlicker};
    unsigned counts[] = {2,2,3,4};
    for (unsigned i=0;i<4;i++) {
        Fixture x = {.steps=preserve[i], .count=counts[i], .closedAt=-1};
        NativeRestoreIO io = {&x, Now, Wait, Read, Close, Record};
        assert(NativeRestoreRunPolicy(io, true, 0, true) == NativeRestorePreserved && x.closes == 0);
        if (i >= 2) assert(x.time >= 5.5); // replacement/publication restores normal grace
    }
    Step fastPending[] = {{0, STATE(0)}, {1.5, STATE(1)}};
    f = (Fixture){.steps=fastPending, .count=2, .closedAt=-1};
    assert(NativeRestoreRunPolicy((NativeRestoreIO){&f,Now,Wait,Read,Close,Record},true,0,true) == NativeRestoreUnconfirmed);
    assert(f.closes == 1 && f.time-f.closedAt >= 10 && !strcmp(f.finalPhase,"disconnect-timeout"));
    Step lateCallback[] = {{0, STATE(0)}, {16, {true, 0, 1, 1}}};
    f = (Fixture){.steps=lateCallback, .count=2, .closedAt=-1};
    assert(NativeRestoreRunPolicy((NativeRestoreIO){&f,Now,Wait,Read,Close,Record},true,0,true) == NativeRestorePreserved);
    assert(f.closes == 1 && f.closedAt < 1.1 && f.time >= 16.3); // same 18 s total, not early close + 10 s
    for (unsigned i=0;i<3;i++) {
        f = (Fixture){.steps=i==0?wrong:i==1?unknown:absent,.count=1,.closedAt=-1};
        assert(NativeRestoreRunPolicy((NativeRestoreIO){&f,Now,Wait,Read,Close,Record},i!=2,0,true) == NativeRestoreUnconfirmed);
        assert(f.closes == 0);
    }
    puts("NATIVE_RESTORE PASS: delayed publication, stable preservation, single write, pending-close barrier, callback/handle generations, deadline, unknown state and pre-write recheck.");
    return 0;
}
