// Diagnostic builds only. No XPC sends, file I/O, timers, host notifications,
// or access to the lease/priority state machine. All retained payload is bounded.
#ifndef SONOFERRY_VOLUME_OBSERVER_H
#define SONOFERRY_VOLUME_OBSERVER_H
#include <CoreFoundation/CoreFoundation.h>
#include <xpc/xpc.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

#define SONOFERRY_VOLUME_DIAGNOSTIC_ID "hal-volume-diag1"
#define VO_MAX_OBJECTS 8
#define VO_MAX_EVENTS 128
#define VO_UID_BYTES 256
enum { VO_BEGIN=100, VO_END=101, VO_INTERRUPTED=102, VO_CONFLICT=103 };
typedef struct {
    bool scalarKnown, absoluteKnown, absolute;
    double scalar;
    uint64_t scalarAt, absoluteAt;
    int scalarSource, absoluteSource;
} VOValues;
typedef struct {
    char uid[VO_UID_BYTES];
    uint32_t type, epoch;
    bool published, closeSeen, conflict;
    VOValues values;
} VOObject;
typedef struct {
    uint64_t sequence, ticks;
    int kind, object;
    uint32_t epoch;
    VOValues values;
} VOEvent;
typedef struct {
    uint64_t generation, started, sequence, received, malformed, unbound, ignored,
        overflow, historyDropped, stale, unknown19;
    bool active;
    char address[18];
    double ticksPerSecond;
    unsigned count, historyCount, historyNext;
    VOObject objects[VO_MAX_OBJECTS];
    VOEvent events[VO_MAX_EVENTS];
} VOState;
static pthread_mutex_t gVOMutex = PTHREAD_MUTEX_INITIALIZER;
static VOState gVO;

static bool VONormalize(const char *in, char out[18]) {
    if (!in || strnlen(in,18)!=17) return false;
    for (unsigned i=0;i<17;i++) {
        unsigned char c=in[i];
        if (i%3==2) { if(c!=':'&&c!='-')return false; out[i]=':'; }
        else { if(c>='a'&&c<='f')c-=32; if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return false; out[i]=c; }
    }
    out[17]=0; return true;
}
static void VOAppend(int kind,int object,uint64_t ticks) {
    VOEvent *e=&gVO.events[gVO.historyNext];
    *e=(VOEvent){.sequence=++gVO.sequence,.ticks=ticks,.kind=kind,.object=object};
    if(object>=0) {e->epoch=gVO.objects[object].epoch;e->values=gVO.objects[object].values;}
    gVO.historyNext=(gVO.historyNext+1)%VO_MAX_EVENTS;
    if(gVO.historyCount<VO_MAX_EVENTS)gVO.historyCount++;else gVO.historyDropped++;
}
static void VOBegin(uint64_t generation,CFStringRef address,double ticksPerSecond) {
    char raw[18]={0},normalized[18]={0};
    bool valid=address&&CFGetTypeID(address)==CFStringGetTypeID()&&
        CFStringGetCString(address,raw,sizeof(raw),kCFStringEncodingASCII)&&VONormalize(raw,normalized)&&
        isfinite(ticksPerSecond)&&ticksPerSecond>0;
    pthread_mutex_lock(&gVOMutex);
    memset(&gVO,0,sizeof(gVO));gVO.generation=generation;gVO.started=mach_absolute_time();
    gVO.ticksPerSecond=ticksPerSecond;gVO.active=valid;
    if(valid)memcpy(gVO.address,normalized,sizeof(normalized));else gVO.malformed++;
    VOAppend(VO_BEGIN,-1,gVO.started);pthread_mutex_unlock(&gVOMutex);
}
static void VOEnd(uint64_t generation,int reason) {
    pthread_mutex_lock(&gVOMutex);
    if(gVO.active&&gVO.generation==generation){
        gVO.active=false;
        for(unsigned i=0;i<gVO.count;i++)gVO.objects[i].published=false;
        VOAppend(reason,-1,mach_absolute_time());
        // Keep anonymous history for a final read; discard routing identities.
        memset(gVO.address,0,sizeof(gVO.address));
        for(unsigned i=0;i<gVO.count;i++)memset(gVO.objects[i].uid,0,VO_UID_BYTES);
    }
    pthread_mutex_unlock(&gVOMutex);
}
static bool VOInteger(xpc_object_t value,int64_t *out) {
    if(!value)return false;
    if(xpc_get_type(value)==XPC_TYPE_INT64){*out=xpc_int64_get_value(value);return true;}
    if(xpc_get_type(value)==XPC_TYPE_UINT64){uint64_t v=xpc_uint64_get_value(value);if(v>INT64_MAX)return false;*out=(int64_t)v;return true;}
    return false;
}
// Called with the observer mutex only. Missing fields remain unknown/unchanged;
// malformed fields invalidate previous knowledge instead of preserving stale data.
static bool VOReadValues(VOObject *o,xpc_object_t properties,int source,uint64_t now) {
    bool touched=false;xpc_object_t v=xpc_dictionary_get_value(properties,"kBTAudioMsgPropertyVolumeScalar");
    if(v){
        touched=true;double scalar=NAN;int64_t integer;
        if(xpc_get_type(v)==XPC_TYPE_DOUBLE)scalar=xpc_double_get_value(v);
        else if(VOInteger(v,&integer))scalar=(double)integer;
        o->values.scalarKnown=isfinite(scalar)&&scalar>=0&&scalar<=1;
        o->values.scalar=o->values.scalarKnown?scalar:0;
        o->values.scalarAt=now;o->values.scalarSource=source;
        if(!o->values.scalarKnown)gVO.malformed++;
    }
    v=xpc_dictionary_get_value(properties,"kBTAudioMsgPropertyVolumeIsAbsolute");
    if(v){
        touched=true;o->values.absoluteKnown=xpc_get_type(v)==XPC_TYPE_BOOL;
        o->values.absolute=o->values.absoluteKnown&&xpc_bool_get_value(v);
        o->values.absoluteAt=now;o->values.absoluteSource=source;
        if(!o->values.absoluteKnown)gVO.malformed++;
    }
    return touched;
}
static void VOObserve(xpc_object_t event,uint64_t generation) {
    if(xpc_get_type(event)==XPC_TYPE_ERROR){VOEnd(generation,VO_INTERRUPTED);return;}
    if(xpc_get_type(event)!=XPC_TYPE_DICTIONARY)return;
    pthread_mutex_lock(&gVOMutex);
    if(generation!=gVO.generation){gVO.stale++;goto done;}
    if(!gVO.active)goto done;
    gVO.received++;int64_t id=0;
    if(!VOInteger(xpc_dictionary_get_value(event,"kBTAudioMsgId"),&id)){gVO.malformed++;goto done;}
    if(id!=2&&id!=3&&id!=4&&id!=19){gVO.ignored++;goto done;}
    const char *uid=xpc_dictionary_get_string(event,"kBTAudioMsgDeviceUid");
    if(!uid||!uid[0]||strnlen(uid,VO_UID_BYTES)>=VO_UID_BYTES){gVO.malformed++;goto done;}
    int index=-1;for(unsigned i=0;i<gVO.count;i++)if(!strcmp(uid,gVO.objects[i].uid)){index=(int)i;break;}
    uint64_t now=mach_absolute_time();
    if(id==2){
        xpc_object_t args=xpc_dictionary_get_value(event,"kBTAudioMsgArgs");
        if(!args||xpc_get_type(args)!=XPC_TYPE_DICTIONARY){gVO.malformed++;goto done;}
        xpc_object_t properties=xpc_dictionary_get_value(args,"kBTAudioMsgArgDeviceProperties");
        int64_t type=0;char address[18];
        if(!properties||xpc_get_type(properties)!=XPC_TYPE_DICTIONARY||
            !VOInteger(xpc_dictionary_get_value(args,"kBTAudioMsgArgDeviceType"),&type)||type<=0||type>UINT32_MAX||
            !VONormalize(xpc_dictionary_get_string(properties,"kBTAudioMsgPropertyDeviceAddress"),address)){
            gVO.malformed++;goto done;
        }
        bool matches=!strcmp(address,gVO.address);
        if(index>=0&&(!matches||gVO.objects[index].type!=(uint32_t)type)){
            VOObject *o=&gVO.objects[index];o->conflict=true;o->published=false;o->values=(VOValues){0};
            gVO.malformed++;VOAppend(VO_CONFLICT,index,now);goto done;
        }
        if(!matches){gVO.ignored++;goto done;}
        if(index<0){
            if(gVO.count==VO_MAX_OBJECTS){gVO.overflow++;goto done;}
            index=(int)gVO.count++;VOObject *o=&gVO.objects[index];
            memcpy(o->uid,uid,strlen(uid)+1);o->type=(uint32_t)type;
        }
        VOObject *o=&gVO.objects[index];if(o->conflict)goto done;
        if(!o->published){o->epoch++;o->values=(VOValues){0};}
        o->published=true;
        VOReadValues(o,properties,2,now);VOAppend(2,index,now);
    }else{
        if(index<0){gVO.unbound++;goto done;}
        VOObject *o=&gVO.objects[index];
        if(id==4){o->published=false;o->closeSeen=true;VOAppend(4,index,now);goto done;}
        if(!o->published||o->conflict){gVO.stale++;goto done;}
        if(id==19){gVO.unknown19++;VOAppend(19,index,now);goto done;}
        xpc_object_t args=xpc_dictionary_get_value(event,"kBTAudioMsgArgs");
        if(!args||xpc_get_type(args)!=XPC_TYPE_DICTIONARY){gVO.malformed++;goto done;}
        if(VOReadValues(o,args,3,now))VOAppend(3,index,now);
    }
done:pthread_mutex_unlock(&gVOMutex);
}
static void VONumber(CFMutableDictionaryRef d,CFStringRef key,int64_t value) {
    CFNumberRef n=CFNumberCreate(NULL,kCFNumberSInt64Type,&value);if(n){CFDictionarySetValue(d,key,n);CFRelease(n);}
}
static void VODouble(CFMutableDictionaryRef d,CFStringRef key,double value) {
    CFNumberRef n=CFNumberCreate(NULL,kCFNumberDoubleType,&value);if(n){CFDictionarySetValue(d,key,n);CFRelease(n);}
}
static void VOBool(CFMutableDictionaryRef d,CFStringRef key,bool value){CFDictionarySetValue(d,key,value?kCFBooleanTrue:kCFBooleanFalse);}
static CFMutableDictionaryRef VODictionary(void){return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);}
static double VOElapsed(const VOState *s,uint64_t ticks){return s->ticksPerSecond>0&&ticks>=s->started?(ticks-s->started)/s->ticksPerSecond:0;}
static void VOValueDictionary(CFMutableDictionaryRef d,const VOValues *v,const VOState *s){
    VOBool(d,CFSTR("scalarKnown"),v->scalarKnown);VOBool(d,CFSTR("absoluteKnown"),v->absoluteKnown);
    if(v->scalarKnown)VODouble(d,CFSTR("scalar"),v->scalar);
    if(v->absoluteKnown)VOBool(d,CFSTR("absolute"),v->absolute);
    if(v->scalarAt){VODouble(d,CFSTR("scalarAtSeconds"),VOElapsed(s,v->scalarAt));CFDictionarySetValue(d,CFSTR("scalarSource"),v->scalarSource==2?CFSTR("publishSnapshot"):CFSTR("propertyUpdate"));}
    if(v->absoluteAt){VODouble(d,CFSTR("absoluteAtSeconds"),VOElapsed(s,v->absoluteAt));CFDictionarySetValue(d,CFSTR("absoluteSource"),v->absoluteSource==2?CFSTR("publishSnapshot"):CFSTR("propertyUpdate"));}
}
// Copy a fixed POD under a separate short lock. Allocate/serialize outside it;
// readers never hold the lease mutex or wait on the lease dispatch queue.
static CFPropertyListRef VOCopySnapshot(void){
    VOState s;pthread_mutex_lock(&gVOMutex);s=gVO;pthread_mutex_unlock(&gVOMutex);
    CFMutableDictionaryRef d=VODictionary();
    CFDictionarySetValue(d,CFSTR("diagnosticBuild"),CFSTR(SONOFERRY_VOLUME_DIAGNOSTIC_ID));
    VONumber(d,CFSTR("schema"),1);VOBool(d,CFSTR("readOnly"),true);VOBool(d,CFSTR("connectionActive"),s.active);
    VOBool(d,CFSTR("remoteAcknowledgementProven"),false);VONumber(d,CFSTR("generation"),(int64_t)s.generation);
    VONumber(d,CFSTR("sequence"),(int64_t)s.sequence);VODouble(d,CFSTR("elapsedSeconds"),VOElapsed(&s,mach_absolute_time()));
    CFMutableDictionaryRef counts=VODictionary();
#define VO_COUNTER(name) VONumber(counts,CFSTR(#name),(int64_t)s.name)
    VO_COUNTER(received);VO_COUNTER(malformed);VO_COUNTER(unbound);VO_COUNTER(ignored);VO_COUNTER(overflow);VO_COUNTER(historyDropped);VO_COUNTER(stale);VO_COUNTER(unknown19);
#undef VO_COUNTER
    CFDictionarySetValue(d,CFSTR("counts"),counts);CFRelease(counts);
    CFMutableArrayRef objects=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    for(unsigned i=0;i<s.count;i++){
        VOObject *o=&s.objects[i];CFMutableDictionaryRef row=VODictionary();
        VONumber(row,CFSTR("object"),i+1);VONumber(row,CFSTR("typeCode"),o->type);VONumber(row,CFSTR("epoch"),o->epoch);
        // Only printable fourccs reach the public snapshot, never device identifiers.
        char type[5]={(char)(o->type>>24),(char)(o->type>>16),(char)(o->type>>8),(char)o->type,0};
        for(unsigned j=0;j<4;j++)if(type[j]<32||type[j]>126)type[j]='?';
        CFStringRef text=CFStringCreateWithCString(NULL,type,kCFStringEncodingASCII);CFDictionarySetValue(row,CFSTR("type"),text);CFRelease(text);
        VOBool(row,CFSTR("published"),o->published);VOBool(row,CFSTR("closeSeen"),o->closeSeen);VOBool(row,CFSTR("conflict"),o->conflict);
        VOValueDictionary(row,&o->values,&s);CFArrayAppendValue(objects,row);CFRelease(row);
    }
    CFDictionarySetValue(d,CFSTR("objects"),objects);CFRelease(objects);
    CFMutableArrayRef events=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    for(unsigned j=0;j<s.historyCount;j++){
        VOEvent *e=&s.events[(s.historyNext+VO_MAX_EVENTS-s.historyCount+j)%VO_MAX_EVENTS];CFMutableDictionaryRef row=VODictionary();
        VONumber(row,CFSTR("sequence"),(int64_t)e->sequence);VONumber(row,CFSTR("event"),e->kind);VONumber(row,CFSTR("object"),e->object+1);
        VONumber(row,CFSTR("epoch"),e->epoch);VODouble(row,CFSTR("atSeconds"),VOElapsed(&s,e->ticks));
        if(e->object>=0)VOValueDictionary(row,&e->values,&s);
        CFArrayAppendValue(events,row);CFRelease(row);
    }
    CFDictionarySetValue(d,CFSTR("events"),events);CFRelease(events);
    CFPropertyListRef immutable=CFPropertyListCreateDeepCopy(NULL,d,kCFPropertyListImmutable);CFRelease(d);return immutable;
}
#endif
