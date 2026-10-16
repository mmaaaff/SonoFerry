#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "ldacBT.h"
#include "ldacdec.h"

// The decoder is a separate, pinned implementation; never linked into the app.
int main(void) {
    const int rates[] = {44100, 48000, 88200, 96000};
    for (unsigned r=0; r<4; r++) for (int mode=0; mode<3; mode++) {
        HANDLE_LDAC_BT encoder=ldacBT_get_handle(); assert(encoder);
        assert(ldacBT_init_handle_encode(encoder,679,mode,LDACBT_CHANNEL_MODE_STEREO,LDACBT_SMPL_FMT_F32,rates[r])==0);
        ldacdec_t decoder; memset(&decoder,0,sizeof(decoder)); ldacdecInit(&decoder);
        uint64_t samples=0; double re[2]={0},im[2]={0},wrongRe[2]={0},wrongIm[2]={0};
        unsigned decodedFrames=0;
        for (unsigned block=0; block<516; block++) {
            float pcm[256]; uint8_t encoded[LDACBT_MAX_NBYTES]={0};
            for (unsigned i=0;i<128;i++) {
                pcm[i*2]=.2*sin(2*M_PI*997*(block*128+i)/rates[r]);
                pcm[i*2+1]=.2*sin(2*M_PI*1601*(block*128+i)/rates[r]);
            }
            int used=0,bytes=0,frames=0;
            assert(ldacBT_encode(encoder,block<512?pcm:NULL,&used,encoded,&bytes,&frames)==0);
            assert(used==(block<512?sizeof(pcm):0));
            if(block>=512 && !bytes) break;
            int offset=0,packetFrames=0;
            while(offset<bytes) {
                int16_t decoded[512]; int consumed=0;
                assert(ldacDecode(&decoder,encoded+offset,decoded,&consumed)==0);
                assert(consumed>0 && consumed<=bytes-offset);
                assert(ldacdecGetSampleRate(&decoder)==rates[r] && ldacdecGetChannelCount(&decoder)==2);
                unsigned generated=decoder.frame.frameSamples;
                assert(generated==(rates[r]>48000?256:128));
                for(unsigned i=0;i<generated;i++) for(unsigned ch=0;ch<2;ch++) {
                    if(samples+i<rates[r]/10 || samples+i>=512*128) continue;
                    double value=decoded[i*2+ch]/32768.0,t=(double)(samples+i)/rates[r];
                    double f=ch==0?997:1601,wrong=ch==0?1601:997;
                    re[ch]+=value*cos(2*M_PI*f*t); im[ch]+=value*sin(2*M_PI*f*t);
                    wrongRe[ch]+=value*cos(2*M_PI*wrong*t); wrongIm[ch]+=value*sin(2*M_PI*wrong*t);
                }
                samples+=generated;offset+=consumed;packetFrames++;decodedFrames++;
            }
            assert(offset==bytes && packetFrames==frames);
        }
        assert(samples>=512*128 && samples<=512*128+512 && decodedFrames>200);
        for(unsigned ch=0;ch<2;ch++) {
            double tone=hypot(re[ch],im[ch]),wrong=hypot(wrongRe[ch],wrongIm[ch]);
            printf("LDAC_DECODE rate=%d mode=%d channel=%u tone=%g wrongChannelTone=%g samples=%llu\n",rates[r],mode,ch,tone,wrong,samples);
            assert(tone>1 && tone>wrong*10);
        }
        ldacBT_free_handle(encoder);
    }
    return 0;
}
