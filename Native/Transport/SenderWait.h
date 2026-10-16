#ifndef SONOFERRY_SENDER_WAIT_H
#define SONOFERRY_SENDER_WAIT_H
#include <sys/event.h>
#include <errno.h>
#include <stdbool.h>
#include <math.h>
#include <unistd.h>

// One outstanding media SDU. Write readiness is disabled while pacing, and
// PCM readiness is enabled only when starved, so neither can cause an idle spin.
// A bounded timeout lets the owning thread service CoreBluetooth's run loop.
typedef struct {
    int queue, socket, control, pcm, baseline;
    bool draining, needsPCM;
} SenderWait;
enum { SenderWakeTimer = 0, SenderWakeDrain = 1, SenderWakeControl = 2, SenderWakePCM = 4 };

static bool SenderWaitInit(SenderWait *w, int queue, int socket, int control, int pcm, int baseline) {
    *w = (SenderWait){.queue=queue, .socket=socket, .control=control, .pcm=pcm, .baseline=baseline};
    struct kevent changes[3]; int n=0;
    EV_SET(&changes[n++], socket, EVFILT_WRITE, EV_ADD | EV_DISABLE, NOTE_LOWAT, baseline, NULL);
    EV_SET(&changes[n++], control, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (pcm >= 0) EV_SET(&changes[n++], pcm, EVFILT_READ, EV_ADD | EV_DISABLE, 0, 0, NULL);
    return kevent(queue, changes, n, NULL, 0, NULL) == 0;
}

static int SenderWaitOnce(SenderWait *w, bool draining, bool needsPCM, double seconds) {
    if (!isfinite(seconds) || seconds < 0) { errno=EINVAL; return -1; }
    struct kevent changes[2], events[3]; int n=0;
    if (w->draining != draining) {
        EV_SET(&changes[n++], w->socket, EVFILT_WRITE, draining ? EV_ENABLE : EV_DISABLE, 0, 0, NULL);
        w->draining=draining;
    }
    needsPCM = needsPCM && w->pcm >= 0;
    if (w->needsPCM != needsPCM) {
        EV_SET(&changes[n++], w->pcm, EVFILT_READ, needsPCM ? EV_ENABLE : EV_DISABLE, 0, 0, NULL);
        w->needsPCM=needsPCM;
    }
    struct timespec timeout = {.tv_sec=0, .tv_nsec=(long)ceil(fmin(seconds, 0.005)*1e9)};
    int count=kevent(w->queue, changes, n, events, 3, &timeout);
    if (count < 0) return errno == EINTR ? SenderWakeTimer : -1;
    int result=SenderWakeTimer;
    for (int i=0;i<count;i++) {
        struct kevent *e=&events[i];
        if (e->flags & EV_ERROR) { errno=(int)e->data; return -1; }
        if (e->filter == EVFILT_WRITE && e->ident == (uintptr_t)w->socket) {
            // NOTE_LOWAT must represent the same empty-buffer baseline used
            // before sending. Never treat partial space as SDU completion.
            if (e->flags & EV_EOF || e->data != w->baseline) { errno=EIO; return -1; }
            result |= SenderWakeDrain;
        } else if (e->filter == EVFILT_READ && e->ident == (uintptr_t)w->control) {
            result |= SenderWakeControl; // EOF is consumed by the control parser.
        } else if (e->filter == EVFILT_READ && e->ident == (uintptr_t)w->pcm) {
            result |= SenderWakePCM; // EOF/partial PCM retains existing handling.
        } else { errno=EIO; return -1; }
    }
    return result;
}
#endif
