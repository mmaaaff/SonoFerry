#include <assert.h>
#include <stdio.h>
#include <sys/socket.h>
#include <time.h>
#include "../../Native/Transport/SenderWait.h"
#include "../../Native/Transport/SenderStatistics.h"
static double clockSeconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
int main(void) {
    int sockets[2], control[2], pcm[2];
    assert(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets) && !pipe(control) && !pipe(pcm));
    int queue=kqueue(); assert(queue>=0);
    struct kevent change,event; struct timespec immediate={0,0};
    EV_SET(&change,sockets[0],EVFILT_WRITE,EV_ADD|EV_ENABLE,0,0,NULL);
    assert(kevent(queue,&change,1,&event,1,&immediate)==1 && event.data>0);
    int baseline=(int)event.data;
    assert(!setsockopt(sockets[0],SOL_SOCKET,SO_SNDLOWAT,&baseline,sizeof baseline));
    SenderWait w; assert(SenderWaitInit(&w,queue,sockets[0],control[0],pcm[0],baseline));
    // A writable socket AND unread PCM must not wake pacing early or spin.
    assert(write(pcm[1],"123",3)==3);
    double start=clockSeconds();
    for (int i=0;i<10;i++) assert(SenderWaitOnce(&w,false,false,.005)==SenderWakeTimer);
    double idle=clockSeconds()-start; assert(idle>=.045 && idle<1);
    assert(SenderWaitOnce(&w,false,true,.005)&SenderWakePCM);
    char buffer[640]; assert(read(pcm[0],buffer,3)==3);
    // Pending media does not count as drained even though free space remains.
    assert(send(sockets[0],buffer,sizeof buffer,0)==sizeof buffer);
    assert(SenderWaitOnce(&w,true,false,.001)==SenderWakeTimer);
    assert(write(control[1],"stop\n",5)==5);
    assert(SenderWaitOnce(&w,true,false,.005)&SenderWakeControl);
    assert(read(control[0],buffer,5)==5);
    assert(read(sockets[1],buffer,100)==100);
    assert(SenderWaitOnce(&w,true,false,.001)==SenderWakeTimer);
    assert(read(sockets[1],buffer,540)==540);
    assert(SenderWaitOnce(&w,true,false,.005)&SenderWakeDrain);
    // EOFs wake the existing parsers; media EOF is terminal.
    close(pcm[1]); assert(SenderWaitOnce(&w,false,true,.005)&SenderWakePCM);
    close(control[1]); assert(SenderWaitOnce(&w,false,false,.005)&SenderWakeControl);
    close(sockets[1]); assert(SenderWaitOnce(&w,true,false,.005)==-1);
    assert(SenderWaitOnce(&w,false,false,NAN)==-1);
    close(queue); close(sockets[0]); close(control[0]); close(pcm[0]);

    SenderStatistics s={.started=10};
    SenderStatisticsEncode(&s,.00002,.0001); SenderStatisticsEncode(&s,.00009,.003);
    SenderStatisticsDrained(&s,.002,578); SenderStatisticsDrained(&s,.065,640);
    SenderStatisticsPending(&s,1.2); // Still blocked at the next report boundary.
    assert(s.blocks==2 && s.packets==2 && s.bytes==1218 && s.packetMax==640);
    assert(s.encodeMax==.00009 && s.scheduleMax==.003 && s.drainMax==1.2);
    assert(s.over8==1 && s.over50==1 && s.sessionOver50==1);
    SenderStatisticsReset(&s,11);
    assert(s.started==11 && !s.blocks && !s.packets && !s.over8 && !s.drainMax);
    assert(s.sessionDrainMax==1.2 && s.sessionOver8==1);
    SenderStatisticsDrained(&s,1.25,578);
    assert(s.over8==1 && s.sessionOver8==2 && s.sessionDrainMax==1.25);
    printf("SENDER_WAIT PASS: no idle spin (10 waits / %.3fs), pacing, partial/full drain, control/PCM EOF; window maxima and cumulative counters\n",idle);
}
