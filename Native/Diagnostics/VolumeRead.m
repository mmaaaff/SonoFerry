#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

// Public HAL property reads only. No XPC connections, setters, or playback APIs.
static AudioObjectPropertyAddress Prop(UInt32 selector){return (AudioObjectPropertyAddress){selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};}
static id ReadCF(AudioObjectID device,UInt32 selector,OSStatus *status){
    AudioObjectPropertyAddress p=Prop(selector);CFTypeRef value=NULL;UInt32 size=sizeof(value);
    *status=AudioObjectGetPropertyData(device,&p,0,NULL,&size,&value);
    if(*status||size!=sizeof(value)){if(value)CFRelease(value);return nil;}
    return value?CFBridgingRelease(value):nil;
}
int main(void){@autoreleasepool{
    NSMutableDictionary *result=[@{@"readOnly":@YES,@"supported":@NO} mutableCopy];int exitCode=2;
    result[@"time"]=[NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime];
    AudioObjectPropertyAddress p=Prop(kAudioHardwarePropertyDevices);UInt32 size=0;OSStatus status=AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&p,0,NULL,&size);
    result[@"listStatus"]=@(status);
    if(!status&&size>0&&size<=65536){
        AudioObjectID *devices=malloc(size);status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&p,0,NULL,&size,devices);result[@"listStatus"]=@(status);
        for(unsigned i=0;!status&&i<size/sizeof(*devices);i++){
            OSStatus s=0;id uid=ReadCF(devices[i],kAudioDevicePropertyDeviceUID,&s);
            if(s||![uid isKindOfClass:NSString.class]||![uid isEqual:@"local.SonoFerry.ldac-output"])continue;
            AudioObjectID device=devices[i];p=Prop('xmvo');
            if(!AudioObjectHasProperty(device,&p)){result[@"error"]=@"Loaded HAL has no volume observation property; diagnostic HAL is not loaded.";exitCode=3;break;}
            Boolean writable=true;s=AudioObjectIsPropertySettable(device,&p,&writable);
            if(s||writable){result[@"error"]=@"Observation property failed read-only validation.";exitCode=4;break;}
            id value=ReadCF(device,'xmvo',&s);result[@"observationStatus"]=@(s);
            if(s||![value isKindOfClass:NSDictionary.class]||![value[@"diagnosticBuild"] isEqual:@"hal-volume-diag1"]||![value[@"readOnly"] isEqual:@YES]){
                result[@"error"]=@"Invalid or unexpected diagnostic snapshot.";exitCode=4;break;
            }
            result[@"supported"]=@YES;result[@"observation"]=value;
            id revision=ReadCF(device,'xmvr',&s);if(!s&&revision)result[@"driverRevision"]=revision;
            id identity=ReadCF(device,'xmei',&s);if(!s&&identity)result[@"engineIdentity"]=identity;
            id priority=ReadCF(device,'xmpr',&s);if(!s&&[priority isKindOfClass:NSDictionary.class]&&[priority[@"phase"] isKindOfClass:NSString.class])result[@"priorityPhase"]=priority[@"phase"];
            p=Prop(kAudioHardwarePropertyDefaultOutputDevice);AudioObjectID output=0;UInt32 n=sizeof(output);
            s=AudioObjectGetPropertyData(kAudioObjectSystemObject,&p,0,NULL,&n,&output);if(!s)result[@"defaultIsVirtual"]=@(output==device);
            exitCode=0;break;
        }
        free(devices);
    }
    if(exitCode==2)result[@"error"]=@"SonoFerry HAL device was not found; an empty sandbox query does not prove the driver is absent.";
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    if(!json||json.length>131072){puts("{\"error\":\"Snapshot exceeds output limit or cannot be serialized.\"}");return 4;}
    puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);return exitCode;
}}
