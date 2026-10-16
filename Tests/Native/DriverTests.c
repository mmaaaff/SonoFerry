#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#define SONOFERRY_PRIORITY_CHECK 1
#include "../../Native/Driver/SonoFerryOutput.c"

static dispatch_semaphore_t requested;
static atomic_uint_fast64_t requestedAction;
static atomic_uint volumeNotifications;
static atomic_uint muteNotifications;
static atomic_uint iconNotifications;
static atomic_uint terminalNotifications;
static atomic_uint systemRateNotifications;
static CFBundleRef iconBundle;
static atomic_bool rejectRequest;
static AudioServerPlugInDriverRef driver;
static pid_t owner;
static atomic_uint timerWakeups;
static atomic_int deniedClient;
static atomic_uint authenticationChecks;

static Boolean AuthenticateClient(pid_t client) {
    atomic_fetch_add(&authenticationChecks, 1);
    assert(pthread_mutex_lock(&gPlugIn_StateMutex) == 0);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return client != atomic_load(&deniedClient) && (client == owner || client == owner + 1);
}

static OSStatus Changed(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count,
                         const AudioObjectPropertyAddress *properties) {
    assert(pthread_mutex_lock(&gPlugIn_StateMutex) == 0);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (object == kObjectID_Device) {
        for (UInt32 i = 0; i < count; ++i) {
            assert(properties[i].mSelector != kAudioDevicePropertyDeviceIsAlive);
            assert(properties[i].mSelector != kAudioDevicePropertyIsHidden);
            if (properties[i].mSelector == kAudioDevicePropertyVolumeScalar) atomic_fetch_add(&volumeNotifications, 1);
            if (properties[i].mSelector == kAudioDevicePropertyMute) atomic_fetch_add(&muteNotifications, 1);
            if (properties[i].mSelector == kSonoFerryRateControl) atomic_fetch_add(&systemRateNotifications, 1);
            if (properties[i].mSelector == kAudioDevicePropertyIcon) atomic_fetch_add(&iconNotifications, 1);
        }
    }
    if (object == kObjectID_Stream_Output) {
        for (UInt32 i = 0; i < count; ++i)
            if (properties[i].mSelector == kAudioStreamPropertyTerminalType) atomic_fetch_add(&terminalNotifications, 1);
    }
    return noErr;
}

static OSStatus Request(AudioServerPlugInHostRef host, AudioObjectID object, UInt64 action, void *info) {
    assert(object == kObjectID_Device && action && info == NULL);
    assert(pthread_mutex_lock(&gPlugIn_StateMutex) == 0);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    atomic_store(&requestedAction, action);
    dispatch_semaphore_signal(requested);
    return atomic_load(&rejectRequest) ? kAudioHardwareUnspecifiedError : noErr;
}

static OSStatus EmptyStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *data) {
    *data = NULL;
    return noErr;
}

static AudioObjectPropertyAddress Property(UInt32 selector, UInt32 scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}

static OSStatus Set(AudioObjectID object, pid_t client, UInt32 selector, UInt32 scope,
                     UInt32 size, const void *data) {
    AudioObjectPropertyAddress property = Property(selector, scope);
    return (*driver)->SetPropertyData(driver, object, client, &property, 0, NULL, size, data);
}

static void Get(AudioObjectID object, pid_t client, UInt32 selector, UInt32 scope,
                 UInt32 capacity, void *data) {
    AudioObjectPropertyAddress property = Property(selector, scope);
    UInt32 size = 0;
    assert((*driver)->GetPropertyData(driver, object, client, &property, 0, NULL,
                                     capacity, &size, data) == noErr && size == capacity);
}

static UInt32 Available(UInt32 selector, UInt32 scope) {
    UInt32 value;
    Get(kObjectID_Device, owner, selector, scope, sizeof(value), &value);
    return value;
}

static Boolean Lease(pid_t client) {
    CFBooleanRef value;
    Get(kObjectID_Device, client, kSonoFerryLease, kAudioObjectPropertyScopeGlobal, sizeof(value), &value);
    Boolean leased = CFBooleanGetValue(value);
    CFRelease(value);
    return leased;
}

static OSStatus RequestLease(pid_t client, Boolean claim) {
    const void *key = CFSTR("claim");
    const void *value = claim ? kCFBooleanTrue : kCFBooleanFalse;
    CFDictionaryRef request = CFDictionaryCreate(NULL, &key, &value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = Set(kObjectID_Device, client, kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request);
    CFRelease(request);
    return status;
}

static void SetLease(pid_t client, Boolean claim) {
    assert(RequestLease(client, claim) == noErr);
}

static void CheckLeaseProtocol(void) {
    pid_t previousOwner = gLeaseOwner;
    UInt64 deadline = gLeaseDeadline;
    UInt64 generation = gLeaseGeneration;
    CFBooleanRef values[] = {kCFBooleanTrue, kCFBooleanFalse};
    for (UInt32 i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        assert(Set(kObjectID_Device, owner, kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
            sizeof(values[i]), &values[i]) == kAudioHardwareIllegalOperationError);
        assert(gLeaseOwner == previousOwner && gLeaseDeadline == deadline && gLeaseGeneration == generation);
    }
    CFMutableDictionaryRef request = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    assert(Set(kObjectID_Device, owner, kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request) == kAudioHardwareIllegalOperationError);
    CFDictionarySetValue(request, CFSTR("claim"), CFSTR("true"));
    assert(Set(kObjectID_Device, owner, kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request) == kAudioHardwareIllegalOperationError);
    CFDictionarySetValue(request, CFSTR("claim"), kCFBooleanTrue);
    CFDictionarySetValue(request, CFSTR("unknown"), kCFBooleanTrue);
    assert(Set(kObjectID_Device, owner, kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request) == kAudioHardwareIllegalOperationError);
    CFDictionaryRemoveValue(request, CFSTR("claim"));
    assert(Set(kObjectID_Device, owner, kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request) == kAudioHardwareIllegalOperationError);
    CFRelease(request);
    assert(gLeaseOwner == previousOwner && gLeaseDeadline == deadline && gLeaseGeneration == generation);
    assert(Lease(owner) == (previousOwner == owner));
}

static UInt64 WaitRequest(void) {
    assert(dispatch_semaphore_wait(requested, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) == 0);
    dispatch_sync(gLeaseQueue, ^{});
    return atomic_load(&requestedAction);
}

static void RequestNow(void) {
    dispatch_sync(gLeaseQueue, ^{ SonoFerryRequestAvailability(); });
}

static void CheckIdleTimer(void) {
    dispatch_sync(gLeaseQueue, ^{ assert(!gLeaseTimerArmed); });
    unsigned before = atomic_load(&timerWakeups);
    usleep(600000);
    dispatch_sync(gLeaseQueue, ^{ assert(!gLeaseTimerArmed); });
    assert(atomic_load(&timerWakeups) == before);
}

static void Perform(UInt64 action) {
    assert((*driver)->PerformDeviceConfigurationChange(driver, kObjectID_Device, action, NULL) == noErr);
    dispatch_sync(gLeaseQueue, ^{});
}

static OSStatus SetPriority(pid_t client, CFStringRef address, Boolean enabled, Boolean disconnected) {
    CFMutableDictionaryRef request = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(request, CFSTR("address"), address);
    CFDictionarySetValue(request, CFSTR("enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
    if (disconnected) CFDictionarySetValue(request, CFSTR("disconnected"), kCFBooleanTrue);
    OSStatus status = Set(kObjectID_Device, client, kSonoFerryPriority, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request);
    CFRelease(request);
    return status;
}

static OSStatus PreparePriority(pid_t client, CFStringRef address, Boolean enabled, Boolean disconnected) {
    CFMutableDictionaryRef request = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(request, CFSTR("address"), address);
    CFDictionarySetValue(request, CFSTR("enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(request, CFSTR("prepare"), kCFBooleanTrue);
    if (disconnected) CFDictionarySetValue(request, CFSTR("disconnected"), kCFBooleanTrue);
    OSStatus status = Set(kObjectID_Device, client, kSonoFerryPriority, kAudioObjectPropertyScopeGlobal,
        sizeof(request), &request);
    CFRelease(request);
    return status;
}

static void PriorityPhase(CFStringRef phase) {
    CFPropertyListRef state;
    Get(kObjectID_Device, owner, kSonoFerryPriority, kAudioObjectPropertyScopeGlobal, sizeof(state), &state);
    assert(CFEqual(CFDictionaryGetValue(state, CFSTR("phase")), phase));
    if (CFEqual(phase, CFSTR("idle")) || gLeaseOwner != owner || !SonoFerryLeaseValid())
        assert(!CFDictionaryGetValue(state, CFSTR("address")));
    else assert(CFEqual(CFDictionaryGetValue(state, CFSTR("address")), CFSTR("AA:BB:CC:DD:EE:FF")));
    CFRelease(state);
}

static xpc_object_t PriorityPublicationEvent(const char *uid, const char *address, int64_t type) {
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t properties = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(properties, "kBTAudioMsgPropertyDeviceAddress", address);
    xpc_dictionary_set_value(args, "kBTAudioMsgArgDeviceProperties", properties);
    xpc_dictionary_set_int64(args, "kBTAudioMsgArgDeviceType", type);
    xpc_dictionary_set_value(event, "kBTAudioMsgArgs", args);
    xpc_dictionary_set_int64(event, "kBTAudioMsgId", 2);
    xpc_dictionary_set_string(event, "kBTAudioMsgDeviceUid", uid);
    xpc_release(properties);
    xpc_release(args);
    return event;
}

static void PriorityPublication(const char *uid, const char *address, int64_t type) {
    xpc_object_t event = PriorityPublicationEvent(uid, address, type);
    dispatch_sync(gLeaseQueue, ^{ SonoFerryPriorityEvent(event); });
    xpc_release(event);
}

static void PriorityNotification(void) {
    dispatch_sync(gLeaseQueue, ^{ SonoFerryPriorityNotification(); });
}

static void PriorityWithdrawal(const char *uid) {
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(event, "kBTAudioMsgId", 4);
    xpc_dictionary_set_string(event, "kBTAudioMsgDeviceUid", uid);
    dispatch_sync(gLeaseQueue, ^{ SonoFerryPriorityEvent(event); });
    xpc_release(event);
}

static void CheckClientAuthentication(CFStringRef address) {
    UInt64 deadline = gLeaseDeadline;
    UInt64 generation = gLeaseGeneration;
    UInt64 sends = gPriorityCheckSends;
    UInt64 bootstraps = gPriorityCheckBootstraps;
    atomic_store(&deniedClient, owner);
    assert(!Lease(owner));
    assert(RequestLease(owner, true) == kAudioDevicePermissionsError);
    assert(RequestLease(owner, false) == kAudioDevicePermissionsError);
    CFStringRef model = CFSTR("WH-1000XM5");
    assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
        sizeof(model), &model) == kAudioDevicePermissionsError);
    Float64 rate = gDevice_SampleRate == 192000 ? 48000 : 96000;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
        sizeof(rate), &rate) == kAudioDevicePermissionsError);
    assert(PreparePriority(owner, address, false, false) == kAudioDevicePermissionsError);
    assert(SetPriority(owner, address, true, false) == kAudioDevicePermissionsError);
    assert(SetPriority(owner, address, false, true) == kAudioDevicePermissionsError);
    SonoFerryPriorityPhaseWithFailure(CFSTR("observing"), CFSTR("Private target detail"), CFSTR("publicationUnavailable"));
    pid_t readers[] = {owner, owner + 1, owner + 2, 0};
    unsigned checks = atomic_load(&authenticationChecks);
    for (UInt32 i = 0; i < sizeof(readers) / sizeof(readers[0]); ++i) {
        CFDictionaryRef state;
        Get(kObjectID_Device, readers[i], kSonoFerryPriority, kAudioObjectPropertyScopeGlobal,
            sizeof(state), &state);
        assert(CFDictionaryGetCount(state) == 1 &&
            CFEqual(CFDictionaryGetValue(state, CFSTR("phase")), CFSTR("observing")));
        CFRelease(state);
    }
    assert(atomic_load(&authenticationChecks) == checks + 1);
    checks = atomic_load(&authenticationChecks);
    assert(!Lease(owner + 1) && !Lease(owner + 2) && !Lease(0));
    assert(atomic_load(&authenticationChecks) == checks);
    assert(gLeaseOwner == owner && gLeaseDeadline == deadline && gLeaseGeneration == generation);
    assert(gPriorityCheckSends == sends && gPriorityCheckBootstraps == bootstraps);
    atomic_store(&deniedClient, 0);
    CFDictionaryRef state;
    Get(kObjectID_Device, owner, kSonoFerryPriority, kAudioObjectPropertyScopeGlobal, sizeof(state), &state);
    assert(CFDictionaryGetCount(state) == 5 &&
        CFDictionaryContainsKey(state, CFSTR("diagnostics")) &&
        CFEqual(CFDictionaryGetValue(state, CFSTR("address")), CFSTR("AA:BB:CC:DD:EE:FF")) &&
        CFEqual(CFDictionaryGetValue(state, CFSTR("error")), CFSTR("Private target detail")) &&
        CFEqual(CFDictionaryGetValue(state, CFSTR("failureCode")), CFSTR("publicationUnavailable")));
    CFRelease(state);
    SonoFerryPriorityPhase(CFSTR("observing"), NULL);
    assert(Lease(owner) && PreparePriority(owner, address, false, false) == noErr);
}

static void CheckInterruptedOwnerRecovery(void) {
    CFStringRef address = CFSTR("AA:BB:CC:DD:EE:FF");
    CFStringRef nextAddress = CFSTR("00:00:00:00:00:01");
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("lost-owner", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    dispatch_sync(gLeaseQueue, ^{
        SonoFerryOwnerExited(owner, gOwnerWatchGeneration);
        SonoFerryPriorityEvent((xpc_object_t)XPC_ERROR_CONNECTION_INTERRUPTED);
    });
    Perform(WaitRequest());
    assert(!gPriorityOwner && !gLeaseOwner && !gPriorityListening && gPrioritySent && !gPriorityDisconnected);
    pid_t recoveryOwner = owner + 1;
    SetLease(recoveryOwner, true);
    Perform(WaitRequest());
    CFDictionaryRef state;
    Get(kObjectID_Device, recoveryOwner, kSonoFerryPriority, kAudioObjectPropertyScopeGlobal, sizeof(state), &state);
    assert(CFEqual(CFDictionaryGetValue(state, CFSTR("address")), address));
    CFRelease(state);
    assert(SetPriority(recoveryOwner, nextAddress, false, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(recoveryOwner, address, true, false) == kAudioHardwareIllegalOperationError);
    UInt64 sends = gPriorityCheckSends;
    UInt64 bootstraps = gPriorityCheckBootstraps;
    UInt64 generation = gPriorityConnectionGeneration;
    assert(SetPriority(recoveryOwner, address, false, false) == noErr);
    UInt64 deadline = gPriorityDeadline;
    assert(!gPriorityListening && !deadline && !gPriorityUID &&
        gPriorityConnectionGeneration == generation && gPriorityCheckBootstraps == bootstraps);
    for (int attempt = 0; attempt < 3; ++attempt) {
        assert(SetPriority(recoveryOwner, address, false, false) == noErr);
        PriorityPublication("replacement", "AA:BB:CC:DD:EE:FF", 1952538980);
        PriorityNotification();
        assert(gPrioritySent && CFEqual(gPriorityAddress, address) && !gPriorityListening &&
            !gPriorityDeadline && gPriorityWaiting < 0 && gPriorityCheckSends == sends &&
            gPriorityConnectionGeneration == generation && gPriorityCheckBootstraps == bootstraps &&
            CFEqual(gPriorityPhase, CFSTR("cleanup-required")));
    }
    assert(SetPriority(recoveryOwner, nextAddress, false, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(recoveryOwner, address, true, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(owner, address, false, true) == kAudioDevicePermissionsError);
    assert(SetPriority(recoveryOwner, address, false, true) == noErr);
    PriorityPublication("after-confirmed-disconnect", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityCheckSends == sends + 1 && gPriorityCheckStatus == 0 && gPriorityWaiting == 0);
    PriorityNotification();
    assert(PreparePriority(recoveryOwner, nextAddress, false, false) == noErr && CFEqual(gPriorityAddress, nextAddress));
    assert(SetPriority(recoveryOwner, nextAddress, false, false) == noErr && gPriorityCheckSends == sends + 1);
    SetLease(recoveryOwner, false);
    Perform(WaitRequest());
    SetLease(owner, true);
    Perform(WaitRequest());
}

static void CheckPriorityDeadlineOrdering(void) {
    CFStringRef address = CFSTR("AA:BB:CC:DD:EE:FF");
    assert(SetPriority(owner, address, true, false) == noErr);
    xpc_object_t publication = PriorityPublicationEvent("deadline-publication", "AA:BB:CC:DD:EE:FF", 1952538980);
    UInt64 sends = gPriorityCheckSends;
    dispatch_sync(gLeaseQueue, ^{
        gPriorityDeadline = mach_absolute_time();
        SonoFerryPriorityEvent(publication);
        assert(!gPrioritySent && !gPriorityUID && !gPriorityListening && !gPriorityDeadline &&
            gPriorityWaiting < 0 && gPriorityCheckSends == sends && CFEqual(gPriorityAddress, address));
        assert(CFEqual(gPriorityFailureCode, CFSTR("publicationUnavailable")));
    });
    xpc_release(publication);
    assert(SetPriority(owner, address, false, false) == noErr);
    for (int64_t waiting = 2; waiting >= 0; --waiting) {
        assert(SetPriority(owner, address, true, false) == noErr);
        PriorityPublication("deadline-notification", "AA:BB:CC:DD:EE:FF", 1952538980);
        if (waiting != 2) {
            PriorityNotification();
            assert(SetPriority(owner, address, false, false) == noErr);
            if (waiting == 0) PriorityNotification();
        }
        assert(gPriorityWaiting == waiting);
        sends = gPriorityCheckSends;
        dispatch_sync(gLeaseQueue, ^{
            gPriorityDeadline = mach_absolute_time();
            SonoFerryPriorityNotification();
            assert(gPrioritySent && CFEqual(gPriorityAddress, address) &&
                CFEqual(gPriorityPhase, CFSTR("cleanup-required")) && !gPriorityDeadline &&
                !gPriorityListening && gPriorityWaiting < 0 && gPriorityCheckSends == sends);
            assert(!gPriorityFailureCode); // Sent-but-unacknowledged writes are not a missing publication.
        });
        PriorityNotification();
        PriorityPublication("expired-republication", "AA:BB:CC:DD:EE:FF", 1952538980);
        PriorityWithdrawal("deadline-notification");
        assert(gPrioritySent && CFEqual(gPriorityAddress, address) && gPriorityCheckSends == sends);
        UInt64 bootstraps = gPriorityCheckBootstraps;
        assert(SetPriority(owner, address, false, false) == noErr && !gPriorityListening);
        PriorityPublication("retry-cleanup", "AA:BB:CC:DD:EE:FF", 1952538980);
        assert(gPriorityWaiting < 0 && gPriorityCheckSends == sends &&
            gPriorityCheckBootstraps == bootstraps && gPrioritySent && CFEqual(gPriorityAddress, address));
        assert(SetPriority(owner, address, false, true) == noErr);
        PriorityPublication("after-confirmed-disconnect", "AA:BB:CC:DD:EE:FF", 1952538980);
        assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0 && gPriorityCheckSends == sends + 1);
        PriorityNotification();
        PriorityNotification();
        assert(!gPrioritySent && !gPriorityAddress && CFEqual(gPriorityPhase, CFSTR("idle")));
    }
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("deadline-withdrawal", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    assert(SetPriority(owner, address, false, true) == noErr && gPriorityRetiredUID);
    xpc_object_t withdrawal = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(withdrawal, "kBTAudioMsgId", 4);
    xpc_dictionary_set_string(withdrawal, "kBTAudioMsgDeviceUid", "deadline-withdrawal");
    sends = gPriorityCheckSends;
    dispatch_sync(gLeaseQueue, ^{
        gPriorityDeadline = mach_absolute_time();
        SonoFerryPriorityEvent(withdrawal);
        assert(gPrioritySent && CFEqual(gPriorityAddress, address) &&
            CFEqual(gPriorityPhase, CFSTR("cleanup-required")) && !gPriorityDeadline && gPriorityCheckSends == sends);
    });
    xpc_release(withdrawal);
    PriorityWithdrawal("deadline-withdrawal");
    assert(gPrioritySent && gPriorityAddress);
    assert(SetPriority(owner, address, false, true) == noErr);
    PriorityPublication("retry-disconnected", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 0);
    PriorityNotification();
    assert(!gPrioritySent && !gPriorityAddress);
}

static Boolean ReplaceLeaseDuringAuthentication(pid_t client) {
    Boolean authorized = AuthenticateClient(client);
    gClientCheckAuthentication = AuthenticateClient;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    gLeaseDeadline = mach_absolute_time();
    SonoFerryRefreshLease();
    gLeaseOwner = owner + 1;
    gLeaseDeadline = mach_absolute_time() + (UInt64)(gTicksPerSecond * 3);
    SonoFerryRefreshLease();
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return authorized;
}

static void CheckScopedMute(void) {
    AudioObjectPropertyAddress property = Property(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput);
    UInt32 qualifier = kSonoFerryLease;
    UInt32 mute = 0;
    assert(Set(kObjectID_Device, 0, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
        sizeof(mute), &mute) == noErr);
    mute = 1;
    unsigned notifications = atomic_load(&muteNotifications);
    atomic_store(&deniedClient, owner);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == kAudioDevicePermissionsError);
    assert(!gMute_Output_Master_Value && atomic_load(&muteNotifications) == notifications);
    atomic_store(&deniedClient, 0);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == noErr);
    assert(gMute_Output_Master_Value && atomic_load(&muteNotifications) == notifications + 1);
    mute = 0;
    assert(Set(kObjectID_Device, 0, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
        sizeof(mute), &mute) == noErr);
    mute = 1;
    gClientCheckAuthentication = ReplaceLeaseDuringAuthentication;
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == kAudioDevicePermissionsError);
    assert(!gMute_Output_Master_Value && Lease(owner + 1));
    SetLease(owner + 1, false);
    SetLease(owner, true);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == noErr);
    pthread_mutex_lock(&gPlugIn_StateMutex);
    gLeaseDeadline = mach_absolute_time();
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    mute = 0;
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == kAudioDevicePermissionsError);
    assert(gMute_Output_Master_Value);
    SetLease(owner + 1, true);
    assert(!Lease(owner) && Lease(owner + 1));
    assert(Set(kObjectID_Device, owner + 2, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
        sizeof(mute), &mute) == noErr);
    notifications = atomic_load(&muteNotifications);
    mute = 1;
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == kAudioDevicePermissionsError);
    assert(!gMute_Output_Master_Value && atomic_load(&muteNotifications) == notifications && Lease(owner + 1));
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner + 1, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == noErr && gMute_Output_Master_Value);
    qualifier = kSonoFerryModel;
    mute = 0;
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner + 1, &property, sizeof(qualifier), &qualifier,
        sizeof(mute), &mute) == kAudioHardwareIllegalOperationError && gMute_Output_Master_Value);
    SetLease(owner + 1, false);
    SetLease(owner, true);
    dispatch_sync(gLeaseQueue, ^{});
}

static void CheckScopedVolume(void) {
    AudioObjectPropertyAddress property = Property(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput);
    UInt32 qualifier = kSonoFerryLease;
    Float32 volume = 0.625;
    unsigned notifications = atomic_load(&volumeNotifications);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == noErr);
    assert(gVolume_Output_Master_Value == volume && atomic_load(&volumeNotifications) == notifications + 1);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == noErr && atomic_load(&volumeNotifications) == notifications + 1);
    volume = NAN;
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == kAudioHardwareIllegalOperationError);
    volume = 0.25;
    atomic_store(&deniedClient, owner);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == kAudioDevicePermissionsError);
    atomic_store(&deniedClient, 0);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner + 1, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == kAudioDevicePermissionsError);
    pthread_mutex_lock(&gPlugIn_StateMutex);
    gLeaseDeadline = mach_absolute_time();
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == kAudioDevicePermissionsError);
    SetLease(owner + 1, true);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == kAudioDevicePermissionsError);
    assert(gVolume_Output_Master_Value == 0.625 && atomic_load(&volumeNotifications) == notifications + 1);
    property = Property(kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal);
    volume = kVolume_MinDB + (kVolume_MaxDB - kVolume_MinDB) * 0.25;
    assert((*driver)->SetPropertyData(driver, kObjectID_Volume_Output_Master, owner + 1, &property, sizeof(qualifier), &qualifier,
        sizeof(volume), &volume) == noErr && gVolume_Output_Master_Value == 0.5);
    Float32 decibels;
    Get(kObjectID_Volume_Output_Master, owner + 1, kAudioLevelControlPropertyDecibelValue,
        kAudioObjectPropertyScopeGlobal, sizeof(decibels), &decibels);
    assert(decibels == volume && atomic_load(&volumeNotifications) == notifications + 2);
    volume = 0.75;
    unsigned checks = atomic_load(&authenticationChecks);
    assert(Set(kObjectID_Device, owner + 2, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
        sizeof(volume), &volume) == noErr && gVolume_Output_Master_Value == volume);
    assert(atomic_load(&authenticationChecks) == checks && Lease(owner + 1));
    SetLease(owner + 1, false);
    // Allow the old owner's withdrawal to reach the host before reacquiring.
    // Its callback can legitimately remain pending until the final withdrawal.
    dispatch_sync(gLeaseQueue, ^{});
    SetLease(owner, true);
    dispatch_sync(gLeaseQueue, ^{});
}

static void CheckPriority(void) {
    CFStringRef address = CFSTR("aa-bb-cc-dd-ee-ff");
    PriorityPhase(CFSTR("idle"));
    // Replay the follow-up trace: enable with no published target, never submit
    // priority, and fail only after the fixed deadline. Refreshes are read-only.
    assert(SetPriority(owner, address, true, false) == noErr);
    UInt64 initialBootstraps = gPriorityCheckBootstraps, initialSends = gPriorityCheckSends;
    UInt64 originalDeadline = gPriorityDeadline;
    for (int attempt = 0; attempt < 4; ++attempt) {
        dispatch_sync(gLeaseQueue, ^{ gPriorityRefreshAt = mach_absolute_time(); SonoFerryPriorityTick(); });
        assert(gPriorityCheckBootstraps == initialBootstraps + attempt + 1 &&
            gPriorityCheckSends == initialSends && gPriorityDeadline == originalDeadline);
    }
    dispatch_sync(gLeaseQueue, ^{ SonoFerryPriorityTick(); });
    assert(!gPriorityRefreshAt && gPriorityCheckBootstraps == initialBootstraps + 4);
    PriorityPublication("wrong-target", "AA:BB:CC:DD:EE:00", 1952538980);
    assert(gPriorityCheckSends == initialSends);
    PriorityPublication("refreshed-target", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityPublication("refreshed-target", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityCheckSends == initialSends + 1 && !gPriorityRefreshAt);
    PriorityNotification();
    assert(SetPriority(owner, address, false, false) == noErr);
    PriorityNotification(); PriorityNotification();
    assert(SetPriority(owner, address, true, false) == noErr && gPriorityRefreshAt);
    assert(SetPriority(owner, address, false, false) == noErr);
    initialBootstraps = gPriorityCheckBootstraps;
    dispatch_sync(gLeaseQueue, ^{ SonoFerryPriorityTick(); });
    assert(!gPriorityRefreshAt && gPriorityCheckBootstraps == initialBootstraps && !gPriorityFailureCode);
    PriorityPhase(CFSTR("idle"));
    assert(PreparePriority(owner + 1, address, false, false) == kAudioDevicePermissionsError);
    assert(PreparePriority(owner, address, true, false) == kAudioHardwareIllegalOperationError);
    assert(PreparePriority(owner, address, false, true) == kAudioHardwareIllegalOperationError);
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPhase(CFSTR("observing"));
    CheckClientAuthentication(address);
    UInt64 bootstraps = gPriorityCheckBootstraps;
    UInt64 sends = gPriorityCheckSends;
    assert(gPriorityListening && !gPriorityDeadline && !gPrioritySent);
    assert(PreparePriority(owner, address, false, false) == noErr && gPriorityCheckBootstraps == bootstraps);
    PriorityPublication("passive-old", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityPublication("passive-replacement", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(!strcmp(gPriorityUID, "passive-replacement") && gPriorityCheckSends == sends);
    PriorityWithdrawal("passive-replacement");
    assert(!gPriorityUID && !gPriorityStopping && !gPriorityDeadline);
    PriorityPhase(CFSTR("observing"));
    PriorityPublication("passive-fresh", "AA:BB:CC:DD:EE:FF", 1952538980);
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
    // Media events must reach the observer without replacing the coordinator UID.
    assert(gVO.active && gVO.generation == gPriorityConnectionGeneration);
    PriorityPublication("passive-media", "AA:BB:CC:DD:EE:FF", 'tacl');
    unsigned mediaIndex = 0;
    while (mediaIndex < gVO.count && strcmp(gVO.objects[mediaIndex].uid, "passive-media")) ++mediaIndex;
    assert(mediaIndex < gVO.count && gVO.objects[mediaIndex].published);
    PriorityWithdrawal("passive-media");
    assert(!gVO.objects[mediaIndex].published && gVO.objects[mediaIndex].closeSeen);
    assert(!strcmp(gPriorityUID, "passive-fresh") && !gPrioritySent && gPriorityCheckSends == sends &&
        gPriorityCheckBootstraps == bootstraps && gPriorityListening && !gPriorityDeadline);
#endif
    assert(gPriorityCheckSends == sends && SetPriority(owner, address, true, false) == noErr);
    assert(gPriorityCheckBootstraps == bootstraps && gPriorityCheckSends == sends + 1 &&
        gPriorityDeadline && gPriorityWaiting == 2 && !strcmp(gPriorityUID, "passive-fresh"));
    assert(PreparePriority(owner, address, false, false) == kAudioHardwareIllegalOperationError);
    PriorityNotification();
    assert(SetPriority(owner, address, false, false) == noErr);
    PriorityNotification();
    PriorityNotification();
    assert(PreparePriority(owner, address, false, false) == noErr);
    sends = gPriorityCheckSends;
    assert(SetPriority(owner, address, true, false) == noErr && !gPriorityUID && gPriorityDeadline &&
        gPriorityCheckSends == sends);
    PriorityPhase(CFSTR("configuring"));
    PriorityPublication("future-after-enable", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 2 && gPriorityCheckSends == sends + 1);
    PriorityNotification();
    assert(SetPriority(owner, address, false, false) == noErr);
    PriorityNotification();
    PriorityNotification();
    assert(PreparePriority(owner, address, false, false) == noErr);
    sends = gPriorityCheckSends;
    dispatch_sync(gLeaseQueue, ^{
        pthread_mutex_lock(&gPlugIn_StateMutex);
        gPriorityOwner = owner + 1;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        SonoFerryPriorityTick();
    });
    PriorityPhase(CFSTR("idle"));
    assert(!gPriorityListening && gPriorityCheckSends == sends);
    assert(SetPriority(owner + 1, address, true, false) == kAudioDevicePermissionsError);
    assert(SetPriority(owner, CFSTR("not-an-address"), true, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(owner, address, true, true) == kAudioHardwareIllegalOperationError);
    CFPropertyListRef invalid = CFSTR("invalid");
    assert(Set(kObjectID_Device, owner, kSonoFerryPriority, kAudioObjectPropertyScopeGlobal,
        sizeof(invalid), &invalid) == kAudioHardwareIllegalOperationError);
    assert(Set(kObjectID_Device, owner, kSonoFerryPriority, kAudioObjectPropertyScopeGlobal,
        0, &invalid) == kAudioHardwareBadPropertySizeError);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPhase(CFSTR("configuring"));
    assert(!gPriorityConnection && gPriorityNotify == -1 && !gPrioritySent);
    PriorityPublication("unrelated", "00:00:00:00:00:01", 1952538980);
    PriorityPublication("wrong-type", "AA:BB:CC:DD:EE:FF", 1952538981);
    assert(!gPrioritySent && !gPriorityUID);
    PriorityPublication("opaque-published-uid", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPrioritySent && gPriorityWaiting == 2 && gPriorityCheckStatus == 2 &&
        !strcmp(gPriorityUID, "opaque-published-uid"));
    xpc_object_t request = SonoFerryPriorityRequest(gPriorityUID, "AA:BB:CC:DD:EE:FF", 2);
    assert(xpc_dictionary_get_int64(request, "kBTAudioMsgId") == 3 &&
        !strcmp(xpc_dictionary_get_string(request, "kBTAudioMsgDeviceUid"), "opaque-published-uid"));
    xpc_object_t unified = xpc_dictionary_get_value(xpc_dictionary_get_value(request, "kBTAudioMsgArgs"),
        "kBTAudioMsgUnifiedUSBCDict");
    assert(xpc_dictionary_get_int64(unified, "kBTAudioMsgUnifiedUSBCStatus") == 2 &&
        !strcmp(xpc_dictionary_get_string(unified, "kBTAudioMsgUnifiedUSBCBTAddress"), "AA:BB:CC:DD:EE:FF"));
    xpc_release(request);
    PriorityPhase(CFSTR("configuring"));
    PriorityNotification();
    PriorityPhase(CFSTR("configured"));
    assert(!gPriorityDeadline && SetPriority(owner, address, true, false) == noErr);
    assert(SetPriority(owner, CFSTR("00:00:00:00:00:01"), true, false) == kAudioHardwareIllegalOperationError);
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityCheckStatus == 1);
    UInt64 cleanupDeadline = gPriorityDeadline;
    PriorityPhase(CFSTR("stopping"));
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityWaiting == 1);
    PriorityNotification();
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0 && gPriorityDeadline == cleanupDeadline);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("opaque-old", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, false, false) == noErr && gPriorityWaiting == 2);
    PriorityNotification();
    assert(gPriorityWaiting == 1);
    PriorityNotification();
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("opaque-old", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    PriorityWithdrawal("opaque-old");
    PriorityPhase(CFSTR("cleanup-required"));
    PriorityPublication("opaque-new", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == -1 && gPriorityCheckStatus == 2);
    sends = gPriorityCheckSends;
    bootstraps = gPriorityCheckBootstraps;
    assert(SetPriority(owner, address, false, false) == noErr);
    assert(gPriorityWaiting < 0 && gPriorityCheckSends == sends && gPriorityCheckBootstraps == bootstraps &&
        gPrioritySent && CFEqual(gPriorityAddress, CFSTR("AA:BB:CC:DD:EE:FF")));
    assert(SetPriority(owner, address, true, false) == kAudioHardwareIllegalOperationError);
    bootstraps = gPriorityCheckBootstraps;
    assert(SetPriority(owner, address, false, true) == noErr && !strcmp(gPriorityUID, "opaque-new") &&
        gPriorityCheckBootstraps == bootstraps);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityPhase(CFSTR("cleanup-required"));
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPublication("before-confirmed-disconnect", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityNotification();
    bootstraps = gPriorityCheckBootstraps;
    assert(SetPriority(owner, address, false, true) == noErr && !gPriorityUID &&
        gPriorityListening && gPriorityCheckBootstraps == bootstraps);
    PriorityPublication("after-confirmed-disconnect", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPublication("case-withdrawn", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityNotification();
    sends = gPriorityCheckSends;
    bootstraps = gPriorityCheckBootstraps;
    PriorityWithdrawal("case-withdrawn");
    PriorityPhase(CFSTR("cleanup-required"));
    assert(gPriorityPublicationWithdrawn && gPriorityListening && !gPriorityUID);
    assert(SetPriority(owner + 1, address, false, true) == kAudioDevicePermissionsError);
    assert(SetPriority(owner, address, false, false) == noErr);
    PriorityPhase(CFSTR("cleanup-required"));
    assert(SetPriority(owner, address, false, true) == noErr);
    PriorityPhase(CFSTR("idle"));
    assert(!gPriorityListening && !gPriorityDeadline && gPriorityCheckSends == sends &&
        gPriorityCheckBootstraps == bootstraps);
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPublication("case-disconnected", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityNotification();
    sends = gPriorityCheckSends;
    assert(SetPriority(owner, address, false, true) == noErr);
    assert(!gPriorityUID && !strcmp(gPriorityRetiredUID, "case-disconnected"));
    assert(SetPriority(owner, address, false, true) == noErr);
    assert(!strcmp(gPriorityRetiredUID, "case-disconnected"));
    PriorityWithdrawal("unrelated");
    PriorityPhase(CFSTR("cleanup-required"));
    PriorityWithdrawal("case-disconnected");
    PriorityPhase(CFSTR("idle"));
    assert(!gPriorityRetiredUID && !gPriorityListening && !gPriorityDeadline && gPriorityCheckSends == sends);
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPublication("ambiguous-first", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityNotification();
    PriorityPublication("ambiguous-second", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityPhase(CFSTR("cleanup-required"));
    PriorityWithdrawal("ambiguous-first");
    assert(!gPriorityPublicationWithdrawn);
    assert(SetPriority(owner, address, false, true) == noErr);
    PriorityPhase(CFSTR("cleanup-required"));
    assert(gPriorityListening && gPriorityDeadline && !gPriorityRetiredUID);
    PriorityPublication("after-ambiguity", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(PreparePriority(owner, address, false, false) == noErr);
    PriorityPublication("before-interruption", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityNotification();
    dispatch_sync(gLeaseQueue, ^{ SonoFerryPriorityEvent((xpc_object_t)XPC_ERROR_CONNECTION_INTERRUPTED); });
    PriorityPhase(CFSTR("cleanup-required"));
    bootstraps = gPriorityCheckBootstraps;
    assert(!gPriorityListening && !gPriorityUID);
    assert(SetPriority(owner, address, false, true) == noErr && gPriorityListening &&
        gPriorityCheckBootstraps == bootstraps + 1);
    PriorityPublication("after-interruption", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("deadline", "AA:BB:CC:DD:EE:FF", 1952538980);
    dispatch_sync(gLeaseQueue, ^{ gPriorityDeadline = mach_absolute_time() - 1; });
    __block Boolean expiredDeadline = false;
    for (UInt32 attempt = 0; !expiredDeadline && attempt < 20; ++attempt) {
        usleep(100000);
        dispatch_sync(gLeaseQueue, ^{ expiredDeadline = CFEqual(gPriorityPhase, CFSTR("cleanup-required")); });
    }
    assert(expiredDeadline);
    PriorityPhase(CFSTR("cleanup-required"));
    assert(gPrioritySent && gPriorityWaiting < 0 && !gPriorityListening);
    sends = gPriorityCheckSends;
    bootstraps = gPriorityCheckBootstraps;
    assert(SetPriority(owner, address, false, false) == noErr && !gPriorityListening);
    PriorityPublication("after-deadline-retry", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting < 0 && gPriorityCheckSends == sends &&
        gPriorityCheckBootstraps == bootstraps && gPrioritySent);
    assert(SetPriority(owner, address, false, true) == noErr);
    PriorityPublication("after-confirmed-disconnect", "AA:BB:CC:DD:EE:FF", 1952538980);
    assert(gPriorityWaiting == 0 && gPriorityCheckStatus == 0);
    PriorityNotification();
    PriorityPhase(CFSTR("idle"));
    assert(SetPriority(owner, address, true, false) == noErr);
    PriorityPublication("owner-exit", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    dispatch_sync(gLeaseQueue, ^{
        SonoFerryOwnerExited(owner, gOwnerWatchGeneration - 1);
        assert(gLeaseOwner == owner && SonoFerryLeaseValid());
        SonoFerryOwnerExited(owner, gOwnerWatchGeneration);
    });
    PriorityPhase(CFSTR("cleanup-required"));
    assert(gPriorityWaiting == 1);
    Perform(WaitRequest());
    dispatch_sync(gLeaseQueue, ^{ assert(!gLeaseOwner && !SonoFerryAlive() && gLeaseTimerArmed); });
    PriorityNotification();
    PriorityNotification();
    RequestNow();
    PriorityPhase(CFSTR("idle"));
    CheckIdleTimer();
    SetLease(owner, true);
    Perform(WaitRequest());
    CheckInterruptedOwnerRecovery();
    CheckPriorityDeadlineOrdering();
    CheckScopedMute();
    CheckScopedVolume();
}

static void CheckResourceBundle(void) {
    AudioObjectPropertyAddress property = Property(kAudioPlugInPropertyResourceBundle, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_PlugIn, owner, &property, 0, NULL, &size) == noErr && size == sizeof(CFStringRef));
    union { CFStringRef alignment; UInt8 bytes[sizeof(CFStringRef) + 8]; } buffer;
    for (UInt32 capacity = 0; capacity < sizeof(CFStringRef); ++capacity) {
        memset(buffer.bytes, 0xA5, sizeof(buffer.bytes));
        OSStatus status = (*driver)->GetPropertyData(driver, kObjectID_PlugIn, owner, &property,
            0, NULL, capacity, &size, buffer.bytes);
        for (UInt32 i = capacity; i < sizeof(buffer.bytes); ++i) assert(buffer.bytes[i] == 0xA5);
        assert(status == kAudioHardwareBadPropertySizeError);
    }
    memset(buffer.bytes, 0xA5, sizeof(buffer.bytes));
    assert((*driver)->GetPropertyData(driver, kObjectID_PlugIn, owner, &property,
        0, NULL, sizeof(CFStringRef), &size, buffer.bytes) == noErr && size == sizeof(CFStringRef));
    CFStringRef value;
    memcpy(&value, buffer.bytes, sizeof(value));
    assert(value && CFGetTypeID(value) == CFStringGetTypeID() && CFEqual(value, CFSTR("")));
    for (UInt32 i = sizeof(CFStringRef); i < sizeof(buffer.bytes); ++i) assert(buffer.bytes[i] == 0xA5);
    CFRelease(value);
}

static void CheckIdentity(CFStringRef icon, UInt32 terminal) {
    CFStringRef bundleID;
    Get(kObjectID_PlugIn, owner, kAudioPlugInPropertyBundleID, kAudioObjectPropertyScopeGlobal,
        sizeof(bundleID), &bundleID);
    assert(CFEqual(bundleID, CFSTR("local.SonoFerry.LDACOutput")));
    CFRelease(bundleID);
    UInt32 value;
    Get(kObjectID_Device, owner, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
        sizeof(value), &value);
    assert(value == kAudioDeviceTransportTypeVirtual);
    Get(kObjectID_Stream_Output, owner, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal,
        sizeof(value), &value);
    assert(value == terminal);
    AudioObjectPropertyAddress property = Property(kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal);
    assert((*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    UInt32 size;
    Boolean settable = true;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, owner, &property, 0, NULL, &size) == noErr && size == sizeof(CFURLRef));
    assert((*driver)->IsPropertySettable(driver, kObjectID_Device, owner, &property, &settable) == noErr && !settable);
    CFURLRef url = NULL;
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(url) - 1, &size, &url) == kAudioHardwareBadPropertySizeError);
    OSStatus status = (*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(url), &size, &url);
    if (iconBundle) {
        assert(status == noErr && url && size == sizeof(url));
        CFStringRef filename = CFURLCopyLastPathComponent(url);
        assert(CFEqual(filename, icon));
        CFRelease(filename);
        CFRelease(url);
    } else assert(status == kAudioHardwareUnspecifiedError && !url);
    property.mScope = kAudioObjectPropertyScopeOutput;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mScope = kAudioObjectPropertyScopeGlobal;
    property.mElement = 1;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mElement = kAudioObjectPropertyElementMain;
    assert(!(*driver)->HasProperty(driver, kObjectID_Stream_Output, owner, &property));
}

static void CheckRevision(void) {
    AudioObjectPropertyAddress property = Property(kSonoFerryRevision, kAudioObjectPropertyScopeGlobal);
    assert((*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    Boolean settable = true;
    assert((*driver)->IsPropertySettable(driver, kObjectID_Device, owner, &property, &settable) == noErr && !settable);
    CFNumberRef revision = NULL;
    UInt32 size = 0;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, owner, &property, 0, NULL, &size) == noErr && size == sizeof(revision));
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(revision) - 1, &size, &revision) == kAudioHardwareBadPropertySizeError && !revision);
    Get(kObjectID_Device, owner, kSonoFerryRevision, kAudioObjectPropertyScopeGlobal, sizeof(revision), &revision);
    SInt32 value = 0;
    assert(revision && CFGetTypeID(revision) == CFNumberGetTypeID());
    assert(CFNumberGetValue(revision, kCFNumberSInt32Type, &value) && value == kSonoFerryDriverRevision && value == 7);
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL,
        sizeof(revision), &revision) != noErr);
    CFRelease(revision);
    property.mScope = kAudioObjectPropertyScopeOutput;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mScope = kAudioObjectPropertyScopeGlobal;
    property.mElement = 1;
    assert(!(*driver)->HasProperty(driver, kObjectID_Device, owner, &property));
    property.mElement = kAudioObjectPropertyElementMain;
    assert(!(*driver)->HasProperty(driver, kObjectID_PlugIn, owner, &property));
}

static OSStatus RateControl(pid_t client, Boolean enabled, const Float64 *rates, UInt32 count) {
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (UInt32 i = 0; i < count; ++i) {
        CFNumberRef value = CFNumberCreate(NULL, kCFNumberFloat64Type, &rates[i]);
        CFArrayAppendValue(list, value); CFRelease(value);
    }
    const void *keys[] = {CFSTR("enabled"), CFSTR("rates")};
    const void *values[] = {enabled ? kCFBooleanTrue : kCFBooleanFalse, list};
    CFDictionaryRef config = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    OSStatus status = Set(kObjectID_Device, client, kSonoFerryRateControl, kAudioObjectPropertyScopeGlobal, sizeof(config), &config);
    CFRelease(config); CFRelease(list); return status;
}

static void CheckSystemRateControl(pid_t currentOwner) {
    const Float64 lhdc[] = {44100,48000,96000,192000};
    assert(RateControl(owner + 20, true, lhdc, 4) == kAudioDevicePermissionsError);
    assert(RateControl(currentOwner, false, lhdc, 4) == noErr);
    AudioValueRange rates[4];
    Get(kObjectID_Device, currentOwner, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, sizeof(rates), rates);
    AudioStreamRangedDescription formats[4];
    Get(kObjectID_Stream_Output, currentOwner, kAudioStreamPropertyAvailableVirtualFormats, kAudioObjectPropertyScopeGlobal, sizeof(formats), formats);
    for (UInt32 i = 0; i < 4; ++i) assert(rates[i].mMinimum == lhdc[i] && formats[i].mFormat.mSampleRate == lhdc[i]);
    const Float64 invalid[] = {48000, NAN}, duplicate[] = {48000,48000};
    assert(RateControl(currentOwner, true, invalid, 2) == kAudioDeviceUnsupportedFormatError);
    assert(RateControl(currentOwner, true, duplicate, 2) == kAudioHardwareIllegalOperationError);
    assert(RateControl(currentOwner, true, lhdc, 4) == noErr);
    Float64 original = gDevice_SampleRate, rate = 96000;
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
    UInt64 seed = atomic_load(&gClockSeed);
    assert(Set(kObjectID_Device, owner + 20, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    dispatch_sync(gLeaseQueue, ^{});
    assert(atomic_load(&systemRateNotifications) && gDevice_SampleRate == original && atomic_load(&gClockSeed) == seed && !gPendingRateAction);
    SInt64 serial = gSystemRateSerial;
    assert(Set(kObjectID_Device, owner + 20, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr && gSystemRateSerial == serial);
    AudioStreamBasicDescription format = formats[3].mFormat;
    assert(Set(kObjectID_Stream_Output, owner + 20, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, sizeof(format), &format) == noErr);
    CFDictionaryRef request;
    Get(kObjectID_Device, currentOwner, kSonoFerryRateControl, kAudioObjectPropertyScopeGlobal, sizeof(request), &request);
    Float64 requested = 0;
    assert(CFNumberGetValue(CFDictionaryGetValue(request, CFSTR("requestedRate")), kCFNumberFloat64Type, &requested));
    assert(requested == 192000 && gSystemRateSerial == serial + 1 && gDevice_SampleRate == original);
    CFRelease(request);
    rate = 88200;
    assert(Set(kObjectID_Device, owner + 20, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDeviceUnsupportedFormatError);
    assert(RateControl(currentOwner, true, gSampleRates, 5) == kAudioHardwareIllegalOperationError);
    assert(RateControl(currentOwner, false, lhdc, 4) == noErr);
    rate = 96000;
    assert(Set(kObjectID_Device, owner + 20, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDevicePermissionsError);
    // A new lease invalidates the old rate mask before host StopIO arrives.
    // Immediate reconfiguration fails even for a bitrate-only LHDC reconnect.
    pthread_mutex_lock(&gPlugIn_StateMutex); ++gLeaseGeneration; pthread_mutex_unlock(&gPlugIn_StateMutex);
    assert(RateControl(currentOwner, false, lhdc, 4) == kAudioHardwareIllegalOperationError);
    assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    assert(RateControl(currentOwner, false, lhdc, 4) == noErr);
    assert(RateControl(currentOwner, true, lhdc, 4) == noErr);
    pthread_mutex_lock(&gPlugIn_StateMutex); ++gLeaseGeneration; pthread_mutex_unlock(&gPlugIn_StateMutex);
    Get(kObjectID_Device, currentOwner, kSonoFerryRateControl, kAudioObjectPropertyScopeGlobal, sizeof(request), &request);
    assert(!CFBooleanGetValue(CFDictionaryGetValue(request, CFSTR("enabled")))); CFRelease(request);
    assert(Set(kObjectID_Device, owner + 20, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDevicePermissionsError);
    assert(RateControl(currentOwner, false, gSampleRates, 5) == noErr);
    dispatch_sync(gLeaseQueue, ^{});
    puts("HAL_SYSTEM_RATE PASS: live external nominal/stream requests, codec-specific lists, unchanged PCM clock, duplicate/latest requests, malformed control rejection, owner protection, disabled/stale lease rejection.");
}

int main(int argc, const char *argv[]) {
    assert(argc == 1 || argc == 2);
    if (argc == 2) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), true);
        iconBundle = CFBundleCreate(NULL, url);
        CFRelease(url);
        assert(iconBundle && CFEqual(CFBundleGetIdentifier(iconBundle), CFSTR("local.SonoFerry.LDACOutput")));
    }
    driver = SonoFerryVirtualOutput_Create(NULL, kAudioServerPlugInTypeUUID);
    AudioServerPlugInHostInterface host = {.PropertiesChanged = Changed, .CopyFromStorage = EmptyStorage,
        .RequestDeviceConfigurationChange = Request};
    requested = dispatch_semaphore_create(0);
    assert(driver && (*driver)->AddRef(driver) == 1);
    assert((*driver)->Initialize(driver, &host) == noErr);
    dispatch_source_set_event_handler(gLeaseTimer, ^{
        atomic_fetch_add(&timerWakeups, 1);
        SonoFerryRequestAvailability();
    });
    owner = getpid();
    assert(!SonoFerryClientAuthorized(0) && !SonoFerryClientAuthorized(-1));
    assert(!SonoFerryClientAuthorized(owner));
    assert(RequestLease(owner, true) == kAudioDevicePermissionsError);
    gClientCheckAuthentication = AuthenticateClient;
    assert(RequestLease(owner + 2, true) == kAudioDevicePermissionsError);
    assert(!gLeaseOwner && !gLeaseDeadline && !gDesiredAvailable && !gPriorityCheckBootstraps);
    CheckLeaseProtocol();
    CheckIdleTimer();
    CheckResourceBundle();
    CheckRevision();
    CheckIdentity(CFSTR("Headphones.png"), kAudioStreamTerminalTypeHeadphones);
    assert(!Available(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal));
    assert(Available(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal));
    assert(!Available(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput));
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == kAudioHardwareNotRunningError);
    AudioObjectPropertyAddress property = Property(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput);
    UInt32 size = 1;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, owner, &property, 0, NULL, &size) == noErr && !size);
    AudioObjectID unusedObject;
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, owner, &property, 0, NULL, 0, &size, &unusedObject) == noErr);
    AudioServerPlugInCustomPropertyInfo custom[SONOFERRY_CUSTOM_PROPERTY_COUNT];
    Get(kObjectID_Device, owner, kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal,
        sizeof(custom), custom);
    assert(custom[0].mSelector == kSonoFerryLease && custom[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList &&
        custom[0].mQualifierDataType == kAudioServerPlugInCustomPropertyDataTypeNone);
    assert(custom[1].mSelector == kSonoFerryModel && custom[1].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFString);
    assert(custom[2].mSelector == kSonoFerryPriority && custom[2].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(custom[3].mSelector == kSonoFerryRevision && custom[3].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(custom[4].mSelector == kSonoFerryRateControl);
    assert(custom[5].mSelector == kSonoFerryEngineIdentity && custom[5].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFString);
    AudioObjectPropertyAddress identityProperty = Property(kSonoFerryEngineIdentity, kAudioObjectPropertyScopeGlobal);
    Boolean identitySettable = true;
    assert((*driver)->IsPropertySettable(driver, kObjectID_Device, owner, &identityProperty, &identitySettable) == noErr && !identitySettable);
    CFStringRef identity = NULL;
    Get(kObjectID_Device, owner, kSonoFerryEngineIdentity, kAudioObjectPropertyScopeGlobal, sizeof(identity), &identity);
    assert(identity && CFEqual(identity, CFSTR(SONOFERRY_ENGINE_CDHASH)));
    assert((*driver)->SetPropertyData(driver, kObjectID_Device, owner, &identityProperty, 0, NULL, sizeof(identity), &identity) != noErr);
    CFRelease(identity);
    assert(!gPriorityConnection && gPriorityNotify == -1 && CFEqual(gPriorityPhase, CFSTR("idle")));
    CFStringRef initialName;
    Get(kObjectID_Device, owner, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
        sizeof(initialName), &initialName);
    assert(CFEqual(initialName, CFSTR("Headphones · SonoFerry")));
    CFRelease(initialName);
    CFStringRef uid;
    Get(kObjectID_Device, owner, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, sizeof(uid), &uid);
    assert(CFEqual(uid, CFSTR("local.SonoFerry.ldac-output")));
    property = Property(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectID resolved;
    assert((*driver)->GetPropertyData(driver, kObjectID_PlugIn, owner, &property, sizeof(uid), &uid,
                                     sizeof(resolved), &size, &resolved) == noErr && resolved == kObjectID_Device);
    CFRelease(uid);
    Float32 volume;
    UInt32 mute;
    Get(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, sizeof(volume), &volume);
    Get(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, sizeof(mute), &mute);
    assert(volume == 0 && mute == 1);
    volume = 0.5625;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
               sizeof(volume), &volume) == noErr);
    Get(kObjectID_Volume_Output_Master, owner, kAudioLevelControlPropertyScalarValue,
        kAudioObjectPropertyScopeGlobal, sizeof(volume), &volume);
    assert(volume == 0.5625 && atomic_load(&volumeNotifications) == 1);
    Float32 invalid = NAN;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
               sizeof(invalid), &invalid) == kAudioHardwareIllegalOperationError);
    invalid = 1.1;
    assert(Set(kObjectID_Volume_Output_Master, owner, kAudioLevelControlPropertyScalarValue,
               kAudioObjectPropertyScopeGlobal, sizeof(invalid), &invalid) == kAudioHardwareIllegalOperationError);
    volume = kVolume_MinDB;
    assert(Set(kObjectID_Volume_Output_Master, owner, kAudioLevelControlPropertyDecibelValue,
               kAudioObjectPropertyScopeGlobal, sizeof(volume), &volume) == noErr);
    Get(kObjectID_Device, owner, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, sizeof(volume), &volume);
    assert(volume == 0 && atomic_load(&volumeNotifications) == 2);
    mute = 0;
    assert(Set(kObjectID_Mute_Output_Master, owner, kAudioBooleanControlPropertyValue,
               kAudioObjectPropertyScopeGlobal, sizeof(mute), &mute) == noErr);
    Get(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, sizeof(mute), &mute);
    assert(mute == 0 && atomic_load(&muteNotifications) == 1);
    mute = 1;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
               sizeof(mute), &mute) == noErr);
    Get(kObjectID_Mute_Output_Master, owner, kAudioBooleanControlPropertyValue,
        kAudioObjectPropertyScopeGlobal, sizeof(mute), &mute);
    assert(mute == 1 && atomic_load(&muteNotifications) == 2);
    mute = 2;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
               sizeof(mute), &mute) == kAudioHardwareIllegalOperationError);
    AudioStreamRangedDescription formats[5];
    Get(kObjectID_Stream_Output, owner, kAudioStreamPropertyAvailablePhysicalFormats,
        kAudioObjectPropertyScopeGlobal, sizeof(formats), formats);
    AudioValueRange rates[5];
    Get(kObjectID_Device, owner, kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal, sizeof(rates), rates);
    for (UInt32 i = 0; i < 5; ++i) {
        assert(formats[i].mFormat.mSampleRate == gSampleRates[i] && formats[i].mFormat.mChannelsPerFrame == 2 &&
            formats[i].mFormat.mBytesPerFrame == 8 && formats[i].mSampleRateRange.mMinimum == gSampleRates[i] &&
            formats[i].mSampleRateRange.mMaximum == gSampleRates[i]);
        assert(rates[i].mMinimum == gSampleRates[i] && rates[i].mMaximum == gSampleRates[i]);
    }
    Float64 rate = 32000;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
               kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDeviceUnsupportedFormatError);
    rate = 44100;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
               kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDevicePermissionsError);
    rate = 48000;
    assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
               kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    CFStringRef model = CFSTR("WH-1000XM5");
    assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioDevicePermissionsError);
    assert(Set(kObjectID_Device, owner, kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioHardwareIllegalOperationError);
    CFBooleanRef claim = kCFBooleanTrue;
    assert(RequestLease(0, true) == kAudioHardwareIllegalOperationError);
    atomic_store(&rejectRequest, true);
    SetLease(owner, true);
    UInt64 failed = WaitRequest();
    assert(Lease(owner) && !Lease(owner + 1) && !SonoFerryAlive());
    CheckLeaseProtocol();
    assert(gPendingAction == 0);
    atomic_store(&rejectRequest, false);
    RequestNow();
    UInt64 aborted = WaitRequest();
    assert(aborted != failed && !SonoFerryAlive());
    assert((*driver)->AbortDeviceConfigurationChange(driver, kObjectID_Device, aborted, NULL) == noErr);
    Perform(aborted);
    UInt64 stale = WaitRequest();
    assert(!SonoFerryAlive() && stale != aborted);
    assert(RequestLease(owner + 1, true) == kAudioDevicePermissionsError);
    assert(RequestLease(owner + 1, false) == kAudioDevicePermissionsError);
    assert(Set(kObjectID_Device, owner + 1, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioDevicePermissionsError);
    model = CFSTR("");
    assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioHardwareIllegalOperationError);
    model = CFSTR("   ");
    assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioHardwareIllegalOperationError);
    assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(claim), &claim) == kAudioHardwareIllegalOperationError);
    CFMutableStringRef longModel = CFStringCreateMutable(NULL, 0);
    for (int i = 0; i < 129; ++i) CFStringAppend(longModel, CFSTR("X"));
    assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(longModel), &longModel) == kAudioHardwareIllegalOperationError);
    CFRelease(longModel);
    model = CFSTR(" WH-1000XM5 ");
    assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == noErr);
    Get(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model);
    assert(CFEqual(model, CFSTR("WH-1000XM5")));
    CFRelease(model);
    Get(kObjectID_Device, owner, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof(model), &model);
    assert(CFEqual(model, CFSTR("WH-1000XM5 · SonoFerry")));
    CFRelease(model);
    CheckIdentity(CFSTR("Headphones.png"), kAudioStreamTerminalTypeHeadphones);
    assert(!atomic_load(&iconNotifications) && !atomic_load(&terminalNotifications));
    CFStringRef arbitraryNames[] = {CFSTR("OPPO Enco X4"),CFSTR("Unknown Receiver"),CFSTR("Generic Speaker")};
    for (size_t i = 0; i < 3; i++) {
        model = arbitraryNames[i];
        assert(Set(kObjectID_Device, owner, kSonoFerryModel, kAudioObjectPropertyScopeGlobal, sizeof(model), &model) == noErr);
        CheckIdentity(CFSTR("Headphones.png"), kAudioStreamTerminalTypeHeadphones);
        assert(!atomic_load(&iconNotifications) && !atomic_load(&terminalNotifications));
    }
    SetLease(owner, false);
    SetLease(owner + 1, true);
    assert(!Lease(owner) && Lease(owner + 1));
    Perform(stale);
    UInt64 activation = WaitRequest();
    assert(!SonoFerryAlive());
    Perform(stale);
    assert(!SonoFerryAlive() && gPendingAction == activation);
    Perform(activation);
    assert(SonoFerryAlive() && !Available(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal));
    assert(Available(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput));
    assert(Available(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput));
    pid_t rateOwner = owner + 1;
    for (UInt32 i = 0; i < 5; ++i) {
        Float64 before;
        Get(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(before), &before);
        rate = gSampleRates[i];
        UInt64 priorSeed = atomic_load(&gClockSeed);
        SetLease(rateOwner, true);
        assert(Set(kObjectID_Device, owner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == kAudioDevicePermissionsError);
        assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
        UInt64 rateAction = WaitRequest();
        Float64 observed;
        Get(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(observed), &observed);
        assert(observed == before && atomic_load(&gClockSeed) == priorSeed);
        assert((*driver)->StartIO(driver, kObjectID_Device, 1) == kAudioHardwareIllegalOperationError);
        Perform(rateAction);
        Get(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(observed), &observed);
        assert(observed == rate && atomic_load(&gClockSeed) == priorSeed + 1);
        for (UInt32 selector = 0; selector < 2; ++selector) {
            AudioStreamBasicDescription format;
            Get(kObjectID_Stream_Output, rateOwner, selector ? kAudioStreamPropertyVirtualFormat : kAudioStreamPropertyPhysicalFormat,
                kAudioObjectPropertyScopeGlobal, sizeof(format), &format);
            assert(format.mSampleRate == rate && format.mReserved == 0 && format.mBytesPerFrame == 8);
        }
        Float64 ticks = atomic_load(&gClockTicksPerFrame);
        assert(fabs(ticks - gTicksPerSecond / rate) < 0.00001);
        UInt32 period = Available(kAudioDevicePropertyZeroTimeStampPeriod, kAudioObjectPropertyScopeGlobal);
        assert(fabs(period / rate - kDevice_RingBufferSize / 48000.0) <= 1 / rate);
        atomic_store(&gClockAnchor, mach_absolute_time() - (UInt64)ceil(ticks * period * 3));
        Float64 stamp;
        UInt64 time, clockSeed;
        assert((*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1, &stamp, &time, &clockSeed) == noErr);
        assert(stamp >= 3 * period && stamp <= 4 * period &&
            time <= mach_absolute_time() && clockSeed == priorSeed + 1);
        assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
        Float64 different = rate == 96000 ? 48000 : 96000;
        assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, sizeof(different), &different) == kAudioHardwareIllegalOperationError);
        assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    }
    rate = 48000;
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rateFailure = WaitRequest();
    assert((*driver)->AbortDeviceConfigurationChange(driver, kObjectID_Device, rateFailure, NULL) == noErr);
    atomic_store(&rejectRequest, true);
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rejectedRate = WaitRequest();
    assert(!gPendingRateAction && gDevice_SampleRate == 192000);
    atomic_store(&rejectRequest, false);
    Perform(rejectedRate);
    assert(gDevice_SampleRate == 192000);
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rateAbort = WaitRequest();
    assert((*driver)->AbortDeviceConfigurationChange(driver, kObjectID_Device, rateAbort, NULL) == noErr);
    Perform(rateAbort);
    assert(gDevice_SampleRate == 192000);
    assert(Set(kObjectID_Device, rateOwner, kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, sizeof(rate), &rate) == noErr);
    UInt64 rateStale = WaitRequest();
    SetLease(rateOwner, false);
    SetLease(owner, true);
    Perform(rateStale);
    assert(gDevice_SampleRate == 192000 && !gPendingRateAction);
    SetLease(owner, false);
    SetLease(rateOwner, true);
    AudioStreamBasicDescription selectedFormat = formats[1].mFormat;
    assert(Set(kObjectID_Stream_Output, rateOwner, kAudioStreamPropertyPhysicalFormat,
        kAudioObjectPropertyScopeGlobal, sizeof(selectedFormat), &selectedFormat) == noErr);
    Perform(WaitRequest());
    assert(gDevice_SampleRate == 48000);
    selectedFormat.mChannelsPerFrame = 1;
    assert(Set(kObjectID_Stream_Output, rateOwner, kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal, sizeof(selectedFormat), &selectedFormat) == kAudioDeviceUnsupportedFormatError);
    CheckSystemRateControl(rateOwner);
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
    Float64 sampleTime;
    UInt64 hostTime, seed;
    assert((*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1, &sampleTime, &hostTime, &seed) == noErr);
    assert(isfinite(sampleTime) && hostTime > 0 && seed == atomic_load(&gClockSeed));
    Boolean willDo, inPlace;
    assert((*driver)->WillDoIOOperation(driver, kObjectID_Device, 1, kAudioServerPlugInIOOperationWriteMix,
                                       &willDo, &inPlace) == noErr && willDo && inPlace);
    pthread_mutex_lock(&gPlugIn_StateMutex);
    gLeaseDeadline = mach_absolute_time() - 1;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    assert(!Lease(owner + 1) && SonoFerryAlive());
    AudioServerPlugInIOCycleInfo cycle = {0};
    Float32 buffer[2] = {0};
    assert((*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Output, 1,
        kAudioServerPlugInIOOperationWriteMix, 0, &cycle, buffer, NULL) == noErr);
    model = CFSTR("WH-1000XM5");
    assert(Set(kObjectID_Device, owner + 1, kSonoFerryModel, kAudioObjectPropertyScopeGlobal,
               sizeof(model), &model) == kAudioDevicePermissionsError);
    RequestNow();
    UInt64 withdrawal = WaitRequest();
    assert(SonoFerryAlive());
    SetLease(owner, true);
    Perform(withdrawal);
    assert(SonoFerryAlive() && Lease(owner));
    assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    UInt64 expired = WaitRequest();
    assert(!Lease(owner) && SonoFerryAlive());
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
    assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    Perform(expired);
    assert(!SonoFerryAlive() && Available(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal));
    assert(atomic_load(&timerWakeups) > 0);
    CheckIdleTimer();
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == kAudioHardwareNotRunningError);
    SetLease(owner, true);
    Perform(WaitRequest());
    assert(SonoFerryAlive());
    CheckPriority();
    SetLease(owner, false);
    withdrawal = WaitRequest();
    assert(SonoFerryAlive() && !Lease(owner));
    pthread_mutex_lock(&gPlugIn_StateMutex);
    assert(withdrawal == gPendingAction && !gDesiredAvailable);
    Boolean staleWithdrawal = gPendingGeneration != gLeaseGeneration;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    Perform(withdrawal);
    if (staleWithdrawal) {
        assert(SonoFerryAlive()); // A stale host callback must not retire a newer lease.
        UInt64 currentWithdrawal = WaitRequest();
        assert(currentWithdrawal != withdrawal);
        Perform(currentWithdrawal);
    }
    assert(!SonoFerryAlive());
    CheckIdleTimer();
    SetLease(owner, true);
    assert(SetPriority(owner, CFSTR("AA:BB:CC:DD:EE:FF"), true, false) == noErr);
    PriorityPublication("host-release", "AA:BB:CC:DD:EE:FF", 1952538980);
    PriorityNotification();
    assert((*driver)->Release(driver) == 0);
    assert(gLeaseTimer == NULL && gLeaseQueue == NULL && gModel == NULL);
    assert(CFEqual(gPriorityPhase, CFSTR("cleanup-required")) && gPriorityError &&
        !gPriorityConnection && gPriorityNotify == -1 && !gOwnerWatcher && gPriorityCheckStatus == 1);
    dispatch_release(requested);
    printf("HAL_TIMER_CHECK passed: zero idle timer callbacks across four 600 ms windows; %u active timer callbacks; lease expiry, priority deadline and owner-exit cleanup retained.\n", atomic_load(&timerWakeups));
    puts("HAL_CALLBACK_CHECK passed: resource-bundle capacity/canary, activation/withdrawal, request failure, abort, stale generations, timer expiry, PID ownership, model identity, volume/mute, native rates and clocks; empty-bootstrap observing, explicit enable, publication replacement, passive owner loss, priority validation, opaque UID, notification ordering, deferred stop, disconnect-only removal with retained observer, deadline-before-event rejection, cleanup retry refusal before verified disconnect, scoped mute/volume with replacement-owner preservation and unrestricted system controls, and owner-exit cleanup; no live XPC or Bluetooth.");
    return 0;
}
