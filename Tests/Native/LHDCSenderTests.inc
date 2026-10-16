// Real sender + real kqueue/socketpair; no Bluetooth, audio route or playback.
#include <pthread.h>
@interface TestLHDCChannel : NSObject
@property int socketFD;
@property UInt16 outgoingMTU;
@property UInt16 cid;
@end
@implementation TestLHDCChannel
@end

typedef struct { int socket, control; unsigned target, packets; BOOL passed; } SenderPeerTest;
static void *SenderPeerRead(void *argument) {
    SenderPeerTest *peer=argument;
    unsigned wanted=peer->target==500 ? 100 : 200;
    size_t bytes=peer->target==500 ? 642 : peer->target==900 ? 578 : 640;
    uint32_t timestamp=0;
    peer->passed=YES;
    for (unsigned i=0;i<wanted;i++) {
        struct pollfd fd={peer->socket,POLLIN,0};
        if (poll(&fd,1,2000)!=1) { peer->passed=NO; break; }
        uint8_t packet[8206]; ssize_t n=recv(peer->socket,packet,sizeof packet,0);
        if (n!=bytes || packet[0]!=0x80 || packet[1]!=0x60 ||
            (((unsigned)packet[2]<<8)|packet[3])!=i || packet[13]!=(uint8_t)i ||
            ((uint32_t)packet[4]<<24|(uint32_t)packet[5]<<16|(uint32_t)packet[6]<<8|packet[7])!=timestamp ||
            packet[12]!=(peer->target==500 ? 8 : 4)) { peer->passed=NO; break; }
        timestamp+=(packet[12]>>2)*240;
        peer->packets++;
        // Some short host-side stalls; this does not model wireless delivery.
        if (i%30==7) { struct timespec delay={0,7000000}; nanosleep(&delay,NULL); }
    }
    if (!peer->passed) write(peer->control,"stop\n",5);
    return NULL;
}

static BOOL LHDCSenderScenario(unsigned target, unsigned scenario) {
    int sockets[2], control[2], pcm[2];
    if (socketpair(AF_UNIX,SOCK_STREAM,0,sockets) || pipe(control) || pipe(pcm)) return NO;
    int saved=dup(STDIN_FILENO);
    if (saved<0 || dup2(control[0],STDIN_FILENO)<0) return NO;
    DirectMediaProbe *probe=RecoveryProbe(target);
    probe.controlPending=[NSMutableData data];
    probe.pcmFD=pcm[0];
    fcntl(pcm[0],F_SETFL,O_NONBLOCK);
    // Fill enough audio for finite playback, with head wrapping to exercise
    // the two-copy ring extraction at an actual encoded block boundary.
    probe.pcmHead=probe.profile.capacityBytes-128;
    probe.pcmBytes=48000*8*2;
    TestLHDCChannel *channel=[TestLHDCChannel new];
    channel.socketFD=sockets[0]; channel.outgoingMTU=679; channel.cid=123;
    int oldFlags=fcntl(sockets[0],F_GETFL), oldLow=0,oldPipe=0;
    ReadOption(sockets[0],SO_SNDLOWAT,&oldLow); ReadOption(sockets[0],SO_NOSIGPIPE,&oldPipe);
    SenderPeerTest peer={.socket=sockets[1],.control=control[1],.target=target}; pthread_t thread;
    if (scenario==0 && pthread_create(&thread,NULL,SenderPeerRead,&peer)) return NO;
    int controlWrite=control[1];
    if (scenario==1) { // Stop must be handled while a packet cannot drain.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ write(controlWrite,"stop\n",5); });
    } else if (scenario==2) { // CoreBluetooth-style callback during a wait.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ probe.closed=YES; });
    } else if (scenario==3) {
        probe.pcmBytes=0; probe.pcmActive=YES;
        close(pcm[1]); pcm[1]=-1;
    } else if (scenario==4) { close(control[1]); control[1]=-1; }
    else if (scenario==5) {
        LDACProfile profile=probe.profile; ConfigureBuffering(&profile,100,250); probe.profile=profile;
    }
    double started=MonotonicTime();
    BOOL result=FeedLHDC(probe,(CBL2CAPChannel *)(id)channel,.1,scenario==0 ? 1 : 0);
    double elapsed=MonotonicTime()-started;
    BOOL passed=YES;
    if (scenario==0) {
        pthread_join(thread,NULL);
        passed=result && peer.passed && peer.packets==(target==500 ? 100 : 200) &&
            probe.lhdcEncoder->consumed==48000 && !probe.lhdcEncoder->skipped && elapsed>.9 && elapsed<3;
    } else if (scenario==1) passed=result && probe.stopRequested && elapsed<.5 && probe.lhdcEncoder->sequence==1;
    else if (scenario==2) passed=!result && probe.closed && elapsed<.5 && probe.lhdcEncoder->sequence==1;
    else if (scenario==3) passed=!result && probe.failed && !probe.lhdcEncoder->sequence;
    else if (scenario==4) passed=result && probe.stdinEnded && !probe.lhdcEncoder->sequence;
    else if (scenario==5) passed=!result && probe.failed && elapsed>=1.1 && elapsed<2 && probe.lhdcEncoder->sequence==1;
    if (!probe.closed) {
        int low=0,noPipe=0;
        passed &= ReadOption(sockets[0],SO_SNDLOWAT,&low) && low==oldLow &&
            ReadOption(sockets[0],SO_NOSIGPIPE,&noPipe) && noPipe==oldPipe && fcntl(sockets[0],F_GETFL)==oldFlags;
    }
    dup2(saved,STDIN_FILENO); close(saved); close(control[0]);
    if(control[1]>=0)close(control[1]); if(pcm[1]>=0)close(pcm[1]);
    close(sockets[0]); close(sockets[1]);
    printf("LHDC_SENDER_SOCKET target=%u scenario=%u elapsed=%.4f result=%s\n",target,scenario,elapsed,passed ? "PASS" : "FAIL");
    return passed;
}
static BOOL LHDCSenderChecks(void) {
    BOOL passed=YES;
    for (unsigned i=0;i<3;i++) passed &= LHDCSenderScenario((unsigned[]){500,900,1000}[i],0);
    for (unsigned i=1;i<=5;i++) passed &= LHDCSenderScenario(900,i);
    return passed;
}
