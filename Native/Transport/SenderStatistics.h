#ifndef SONOFERRY_SENDER_STATISTICS_H
#define SONOFERRY_SENDER_STATISTICS_H
#include <stdint.h>
#include <math.h>

// Constant storage and O(1) work per block/packet. No per-packet logging.
typedef struct {
    uint64_t packets, bytes, blocks, waits, timeouts, over8, over50;
    unsigned packetMax;
    double started, encodeMax, scheduleMax, drainMax, drainTotal;
    double sessionDrainMax;
    uint64_t sessionOver8, sessionOver50;
} SenderStatistics;
static void SenderStatisticsEncode(SenderStatistics *s, double duration, double late) {
    s->blocks++;
    s->encodeMax=fmax(s->encodeMax, duration);
    s->scheduleMax=fmax(s->scheduleMax, late);
}
static void SenderStatisticsPending(SenderStatistics *s, double duration) {
    s->drainMax=fmax(s->drainMax, duration);
    s->sessionDrainMax=fmax(s->sessionDrainMax, duration);
}
static void SenderStatisticsDrained(SenderStatistics *s, double duration, unsigned bytes) {
    SenderStatisticsPending(s, duration);
    s->packets++; s->bytes+=bytes; s->packetMax=bytes>s->packetMax ? bytes : s->packetMax;
    s->drainTotal+=duration;
    if (duration > 0.008) { s->over8++; s->sessionOver8++; }
    if (duration > 0.050) { s->over50++; s->sessionOver50++; }
}
static void SenderStatisticsReset(SenderStatistics *s, double now) {
    *s=(SenderStatistics){.started=now, .sessionDrainMax=s->sessionDrainMax,
        .sessionOver8=s->sessionOver8, .sessionOver50=s->sessionOver50};
}
#endif
