#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "../../Native/Codec/LHDCBackend.h"
#ifdef SONOFERRY_REFERENCE_DECODE
#include "lhdc_dec.h"
int g_nzc_formula = 0, g_pkframe = 0;
#include <stdlib.h>
#endif
int main(void) {
    const unsigned rates[] = {44100,48000,96000,192000};
    const unsigned targets[] = {400,500,900,1000};
    for (unsigned target = 0; target < 4; target++)
    for (unsigned r = 0; r < 4; r++) for (unsigned bits = 16; bits <= 24; bits += 8) {
        unsigned wanted = rates[r] == 44100 && targets[target] == 500 ? 480 : targets[target];
        unsigned mtu = rates[r] == 44100 && wanted == 1000 ? 696 : 679;
        MacLHDC c; assert(MacLHDCOpen(&c, rates[r], bits, wanted, 64, 1000, mtu, 0x12345678));
        unsigned selected = c.index; bool recovered = false;
        float pcm[1920]; uint8_t packet[8206]; uint64_t previous = 0; unsigned sequence = 0, frames = 0;
        MacLHDCGain(&c, 0.2);
#ifdef SONOFERRY_REFERENCE_DECODE
        lhdc_dec_config_t config = {.sample_rate=rates[r], .bit_depth=bits, .frame_duration=5, .channels=2, .max_frame_bytes=2048};
        void *workspace = calloc(1,lhdc_dec_get_workspace_size(rates[r],5));
        lhdc_decoder_t *decoder = lhdc_dec_init(workspace, &config); assert(decoder);
        double re[2]={0},im[2]={0},wrongRe[2]={0},wrongIm[2]={0}; uint64_t decodedSamples = 0;
#endif
        for (unsigned block = 0; block < 200; block++) {
            // Decode across both directions of a live bitrate transition.
            if (target == 0 && block == 60) assert(MacLHDCAdjust(&c,-1));
            if (target == 0 && block == 120) assert(MacLHDCAdjust(&c,1));
            if (!recovered && block >= 140 && c.consumed == c.emitted) {
                uint16_t sequenceBefore = c.sequence;
                assert(!MacLHDCDiscontinuity(&c, c.block + 1));
                assert(MacLHDCDiscontinuity(&c, c.block * 20));
                assert(c.sequence == sequenceBefore && c.index == selected);
                recovered = true;
            }
            for (unsigned sample = 0; sample < c.block; sample++) {
                pcm[sample*2] = sin(2*M_PI*997*(block*c.block+c.skipped+sample)/rates[r]);
                pcm[sample*2+1] = sin(2*M_PI*1601*(block*c.block+c.skipped+sample)/rates[r]);
            }
            size_t length = 0; unsigned bitrate = 0;
            assert(MacLHDCEncode(&c,pcm,packet,sizeof(packet),&length,&bitrate));
            if (target > 0) assert(c.index == selected);
            if (!length) continue;
            assert(length <= mtu && packet[0] == 0x80 && packet[1] == 0x60);
            if (target > 0) assert(bitrate >= wanted-5 && bitrate <= wanted+5);
            assert(((unsigned)packet[2]<<8|packet[3]) == sequence && packet[13] == (uint8_t)sequence);
            assert(packet[12] && !(packet[12]&3));
            uint32_t ts=(uint32_t)packet[4]<<24|(uint32_t)packet[5]<<16|(uint32_t)packet[6]<<8|packet[7];
            assert(ts == (uint32_t)(previous + c.skipped));
            assert(packet[8] == 0x12 && packet[11] == 0x78);
            previous += (packet[12]>>2)*c.block; frames += packet[12]>>2; sequence++;
#ifdef SONOFERRY_REFERENCE_DECODE
            size_t offset=14; unsigned packetFrames=0;
            while (offset < length) {
                int32_t output[1920]; size_t consumed=0; uint32_t generated=0; lhdc_dec_frame_info_t info;
                int result=lhdc_dec_decode_frame(decoder,packet+offset,length-offset,output,960,&consumed,&generated,&info);
                if (result) fprintf(stderr,"decode error rate=%u bits=%u result=%d offset=%zu\n",rates[r],bits,result,offset);
                assert(result == 0 && consumed && consumed <= length-offset && generated == c.block);
                assert(info.sample_rate==rates[r] && info.channels==2);
                for (unsigned i=0;i<generated;i++) for(unsigned channel=0;channel<2;channel++) {
                    double value=bits==16 ? ((int16_t*)output)[i*2+channel]/32768.0 : output[i*2+channel]/2147483648.0;
                    if(decodedSamples+i>rates[r]/10) {
                        double t=(double)(decodedSamples+i+c.skipped)/rates[r], f=channel==0?997:1601, wrong=channel==0?1601:997;
                        re[channel]+=value*cos(2*M_PI*f*t);im[channel]+=value*sin(2*M_PI*f*t);
                        wrongRe[channel]+=value*cos(2*M_PI*wrong*t);wrongIm[channel]+=value*sin(2*M_PI*wrong*t);
                    }
                }
                decodedSamples+=generated;offset+=consumed;packetFrames++;
            }
            assert(packetFrames==(packet[12]>>2));
#endif
        }
        assert(recovered && c.skipped == c.block * 20);
        assert(sequence > 20 && frames == 200 && c.consumed == previous);
        assert(MacLHDCAdjust(&c,-1)); assert(MacLHDCAdjust(&c,1));
#ifdef SONOFERRY_REFERENCE_DECODE
        for(unsigned ch=0;ch<2;ch++) {
            double energy=hypot(re[ch],im[ch]),wrong=hypot(wrongRe[ch],wrongIm[ch]);
            printf("DECODE rate=%u bits=%u channel=%u tone=%g wrongChannelTone=%g samples=%llu\n",rates[r],bits,ch,energy,wrong,decodedSamples);
            assert(energy>1 && energy>wrong*10);
        }
        lhdc_dec_deinit(decoder);free(workspace);
#endif
        MacLHDCClose(&c);
        printf("LHDC rate=%u bits=%u target=%u packets=%u frames=%u RTP/MTU/recovery=PASS\n",rates[r],bits,targets[target],sequence,frames);
    }
    MacLHDC invalid; assert(!MacLHDCOpen(&invalid,88200,24,400,64,1000,679,1));
    assert(!MacLHDCOpen(&invalid,48000,32,400,64,1000,679,1));
    assert(!MacLHDCOpen(&invalid,48000,24,400,500,1000,679,1));
    assert(MacLHDCMinimumMTU(44100,1000) == 696);
    assert(MacLHDCMinimumMTU(48000,1000) == 640);
    assert(!MacLHDCOpen(&invalid,44100,24,1000,64,1000,679,1));
    assert(!MacLHDCOpen(&invalid,48000,24,1000,64,1000,639,1));
    assert(MacLHDCOpen(&invalid,44100,24,900,64,1000,679,1));
    assert(MacLHDCAdjust(&invalid,1) && invalid.index == 7); // ABR cannot step beyond this MTU.
    MacLHDCClose(&invalid);
    return 0;
}
