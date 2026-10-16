#define SONOFERRY_VOLUME_DIAGNOSTICS 1
#define main DriverRegressionMain
#include "DriverTests.c"
#undef main

static const char *voAddress="A1:B2:C3:D4:E5:F6";
static xpc_object_t VOPublication(const char *uid,const char *address,int64_t type,bool volume) {
    xpc_object_t e=PriorityPublicationEvent(uid,address,type);
    if(volume){xpc_object_t p=xpc_dictionary_get_value(xpc_dictionary_get_value(e,"kBTAudioMsgArgs"),"kBTAudioMsgArgDeviceProperties");
        xpc_dictionary_set_double(p,"kBTAudioMsgPropertyVolumeScalar",0.4);xpc_dictionary_set_bool(p,"kBTAudioMsgPropertyVolumeIsAbsolute",true);}
    return e;
}
static void VOFeed(xpc_object_t event,uint64_t generation){VOObserve(event,generation);xpc_release(event);}
static xpc_object_t VOMessage(const char *uid,int id,double value) {
    xpc_object_t e=xpc_dictionary_create(NULL,NULL,0),a=xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_int64(e,"kBTAudioMsgId",id);xpc_dictionary_set_string(e,"kBTAudioMsgDeviceUid",uid);
    xpc_dictionary_set_double(a,"kBTAudioMsgPropertyVolumeScalar",value);xpc_dictionary_set_value(e,"kBTAudioMsgArgs",a);xpc_release(a);return e;
}
static void CheckObserver(void){
    CFStringRef address=CFSTR("a1-b2-c3-d4-e5-f6");
    VOBegin(10,address,1e9);assert(gVO.active&&gVO.count==0);
    VOFeed(VOMessage("unbound",3,0.8),10);assert(gVO.unbound==1&&gVO.count==0);
    VOFeed(VOPublication("foreign-secret","11:22:33:44:55:66",'tacl',true),10);assert(gVO.count==0);
    VOFeed(VOPublication("coord-private",voAddress,'taad',false),10);
    VOFeed(VOPublication("media-private",voAddress,'tacl',true),10);
    assert(gVO.count==2&&gVO.objects[0].type=='taad'&&gVO.objects[1].type=='tacl');
    assert(!gVO.objects[0].values.scalarKnown&&gVO.objects[1].values.scalarKnown&&gVO.objects[1].values.absolute);
    VOFeed(VOPublication("media-private",voAddress,'tacl',false),10);
    assert(gVO.count==2&&gVO.objects[1].epoch==1&&gVO.objects[1].values.scalar==0.4);
    VOFeed(VOMessage("media-private",3,0.3),9);assert(gVO.objects[1].values.scalar==0.4&&gVO.stale==1);
    VOFeed(VOMessage("media-private",3,0.3),10);assert(gVO.objects[1].values.scalar==0.3&&gVO.objects[1].values.scalarSource==3);
    VOFeed(VOMessage("media-private",19,0.9),10);assert(gVO.objects[1].values.scalar==0.3&&gVO.unknown19==1);
    VOFeed(VOMessage("media-private",4,0),10);assert(!gVO.objects[1].published&&gVO.objects[1].closeSeen);
    VOFeed(VOMessage("media-private",3,0.9),10);assert(gVO.objects[1].values.scalar==0.3);
    VOFeed(VOPublication("media-private",voAddress,'tacl',false),10);
    assert(gVO.objects[1].published&&gVO.objects[1].epoch==2&&!gVO.objects[1].values.scalarKnown&&!gVO.objects[1].values.absoluteKnown);
    VOFeed(VOPublication("media-private",voAddress,'tacl',true),10);
    double bad[]={NAN,INFINITY,-0.1,1.1};
    for(unsigned i=0;i<4;i++){VOFeed(VOMessage("media-private",3,bad[i]),10);assert(!gVO.objects[1].values.scalarKnown);}
    xpc_object_t e=VOMessage("media-private",3,0.6),a=xpc_dictionary_get_value(e,"kBTAudioMsgArgs");
    xpc_dictionary_set_string(a,"kBTAudioMsgPropertyVolumeIsAbsolute","true");VOFeed(e,10);
    assert(gVO.objects[1].values.scalar==0.6&&!gVO.objects[1].values.absoluteKnown);
    e=VOMessage("media-private",3,0.6);a=xpc_dictionary_get_value(e,"kBTAudioMsgArgs");
    xpc_dictionary_set_uint64(a,"kBTAudioMsgPropertyVolumeScalar",UINT64_MAX);VOFeed(e,10);assert(!gVO.objects[1].values.scalarKnown);
    e=VOMessage("media-private",3,0.6);xpc_dictionary_set_string(e,"kBTAudioMsgId","3");VOFeed(e,10);
    assert(!gVO.objects[1].values.scalarKnown);
    char longUID[VO_UID_BYTES+10];memset(longUID,'x',sizeof(longUID)-1);longUID[sizeof(longUID)-1]=0;
    VOFeed(VOPublication(longUID,voAddress,'tacl',true),10);assert(gVO.count==2);
    for(unsigned i=0;i<10;i++){char uid[16];snprintf(uid,sizeof(uid),"extra-%u",i);VOFeed(VOPublication(uid,voAddress,'tacl',true),10);}
    assert(gVO.count==VO_MAX_OBJECTS&&gVO.overflow==4);
    for(unsigned i=0;i<140;i++)VOFeed(VOMessage("media-private",3,0.5),10);
    assert(gVO.historyCount==VO_MAX_EVENTS&&gVO.historyDropped>0);
    CFPropertyListRef snapshot=VOCopySnapshot();CFDataRef serialized=CFPropertyListCreateData(NULL,snapshot,kCFPropertyListXMLFormat_v1_0,0,NULL);
    assert(serialized);CFStringRef xml=CFStringCreateFromExternalRepresentation(NULL,serialized,kCFStringEncodingUTF8);
    assert(CFStringFind(xml,CFSTR("media-private"),0).location==kCFNotFound&&CFStringFind(xml,CFSTR("A1:B2"),0).location==kCFNotFound&&CFStringFind(xml,CFSTR("foreign-secret"),0).location==kCFNotFound);
    assert(CFDictionaryGetValue(snapshot,CFSTR("remoteAcknowledgementProven"))==kCFBooleanFalse);
    CFRelease(xml);CFRelease(serialized);CFRelease(snapshot);
    VOFeed(VOPublication("media-private",voAddress,'taad',true),10);
    assert(gVO.objects[1].conflict&&!gVO.objects[1].published&&!gVO.objects[1].values.scalarKnown);
    VOFeed(VOPublication("media-private",voAddress,'tacl',true),10);assert(!gVO.objects[1].published);
    VOBegin(11,address,1e9);assert(gVO.count==0&&gVO.historyCount==1&&gVO.generation==11);
    VOFeed(VOPublication("media-private",voAddress,'tacl',true),11);
    VOEnd(10,VO_END);assert(gVO.active);VOObserve((xpc_object_t)XPC_ERROR_CONNECTION_INVALID,11);
    assert(!gVO.active&&!gVO.objects[0].published&&!gVO.address[0]&&!gVO.objects[0].uid[0]);
    uint64_t seq=gVO.sequence;VOEnd(11,VO_END);VOFeed(VOMessage("media-private",3,0.7),11);assert(gVO.sequence==seq);
    VOBegin(12,address,1e9);VOFeed(VOPublication("media-private",voAddress,'tacl',true),12);
    dispatch_apply(400,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i){
        if(i%2){VOFeed(VOMessage("media-private",3,0.25),12);}else{CFPropertyListRef v=VOCopySnapshot();assert(v);CFRelease(v);}
    });
    VOEnd(12,VO_END);
    AudioObjectPropertyAddress property=Property(kSonoFerryVolumeObservation,kAudioObjectPropertyScopeGlobal);Boolean writable=true;
    assert(SonoFerryHasProperty(gAudioServerPlugInDriverRef,kObjectID_Device,123,&property));
    assert(SonoFerryIsSettable(gAudioServerPlugInDriverRef,kObjectID_Device,123,&property,&writable)==noErr&&!writable);
    assert(SonoFerrySetData(gAudioServerPlugInDriverRef,kObjectID_Device,123,&property,0,NULL,0,NULL)==kAudioHardwareIllegalOperationError);
    UInt32 size=0;CFPropertyListRef value=NULL;
    assert(SonoFerryGetData(gAudioServerPlugInDriverRef,kObjectID_Device,123,&property,0,NULL,0,&size,&value)==kAudioHardwareBadPropertySizeError);
    assert(SonoFerryGetData(gAudioServerPlugInDriverRef,kObjectID_Device,123,&property,0,NULL,sizeof(value),&size,&value)==noErr&&value);CFRelease(value);
    property.mScope=kAudioObjectPropertyScopeOutput;assert(!SonoFerryHasProperty(gAudioServerPlugInDriverRef,kObjectID_Device,123,&property));
    property.mScope=kAudioObjectPropertyScopeGlobal;property.mElement=1;assert(!SonoFerryHasProperty(gAudioServerPlugInDriverRef,kObjectID_Device,123,&property));
    VOBegin(13,CFSTR("bad"),1e9);assert(!gVO.active);
    // The observer has never started the real priority/lease machinery.
    assert(!gPriorityConnection&&!gPriorityUID&&!gPrioritySent&&!gPriorityCheckSends&&!gPriorityCheckBootstraps&&!gLeaseOwner);
    puts("PASS: volume observer lifecycle, malformed/foreign/stale events, bounds, privacy, concurrent reads, read-only API, no priority sends");
}
int main(int argc,const char *argv[]){CheckObserver();return DriverRegressionMain(argc,argv);}
