#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <unistd.h>
#include <notify.h>
#include <xpc/xpc.h>
#include <CoreAudio/AudioHardware.h>
#include <Security/Security.h>
#include "NullAudio.c"
#include "EngineIdentity.h"
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
#include "VolumeObserver.h"
enum { kSonoFerryVolumeObservation = 'xmvo' };
#define SONOFERRY_CUSTOM_PROPERTY_COUNT 7
#else
#define SONOFERRY_CUSTOM_PROPERTY_COUNT 6
#endif

enum { kSonoFerryLease = 'xmls', kSonoFerryModel = 'xmnm', kSonoFerryPriority = 'xmpr', kSonoFerryRevision = 'xmvr', kSonoFerryEngineIdentity = 'xmei', kSonoFerryRateControl = 'xmrc' };
static const SInt32 kSonoFerryDriverRevision = 7;
static UInt64 gLeaseDeadline;
static pid_t gLeaseOwner;
static atomic_bool gAvailable;
static Boolean gDesiredAvailable;
static UInt64 gLeaseGeneration;
static UInt64 gNextAction;
static UInt64 gPendingAction;
static UInt64 gPendingGeneration;
static Boolean gPendingAvailable;
static Boolean gShuttingDown;
static CFStringRef gModel;
static CFStringRef SonoFerryIconName(CFStringRef model) { (void)model; return CFSTR("Headphones"); }
static UInt32 SonoFerryTerminalType(CFStringRef model) { (void)model; return kAudioStreamTerminalTypeHeadphones; }

static dispatch_source_t gLeaseTimer;
static Boolean gLeaseTimerArmed;
static dispatch_queue_t gLeaseQueue;
static double gTicksPerSecond;
static const Float64 gSampleRates[] = {44100, 48000, 88200, 96000, 192000};
#define SONOFERRY_RATE_COUNT (sizeof(gSampleRates) / sizeof(gSampleRates[0]))
static UInt64 gPendingRateAction;
static Float64 gPendingRate;
static pid_t gPendingRateOwner;
static UInt64 gPendingRateGeneration;
static atomic_uint_fast64_t gClockAnchor;
static atomic_uint_fast64_t gClockSeed;
static atomic_uint gClockPeriod;
static _Atomic(Float64) gClockTicksPerFrame;
static CFStringRef gPriorityPhase;
static CFStringRef gPriorityFailureCode;
static UInt64 gPriorityRefreshAt;
static UInt32 gPriorityRefreshAttempts;
static UInt32 gPriorityBootstrapCount, gPriorityEventCount, gPriorityMatchCount;
static int64_t gPriorityLastEvent;
static CFStringRef gPriorityDiagnostics;
static CFStringRef gPriorityAddress;
static CFStringRef gPriorityError;
static pid_t gPriorityOwner;
static xpc_connection_t gPriorityConnection;
static char *gPriorityUID;
static char *gPriorityRetiredUID;
static int gPriorityNotify = -1;
static int64_t gPriorityWaiting = -1;
static UInt64 gPriorityDeadline;
static UInt64 gPriorityConnectionGeneration;
static Boolean gPrioritySent;
static Boolean gPriorityEnabling;
static Boolean gPriorityStopping;
static Boolean gPriorityDisconnected;
static Boolean gPriorityPublicationLost;
static Boolean gPriorityPublicationWithdrawn;
static Boolean gPriorityListening;
static Boolean gPriorityUIDAfterLoss;
static dispatch_source_t gOwnerWatcher;
static pid_t gWatchedOwner;
static UInt64 gOwnerWatchGeneration;
static char gLeaseQueueKey;
static void SonoFerryLeaseChanged(void);
static void SonoFerryRequestAvailability(void);
static void SonoFerryScheduleLeaseTimer(void);

#ifdef SONOFERRY_PRIORITY_CHECK
static Boolean (*gClientCheckAuthentication)(pid_t);
#endif

static Boolean SonoFerryClientAuthorized(pid_t client) {
    if (client <= 0) return false;
#ifdef SONOFERRY_PRIORITY_CHECK
    if (gClientCheckAuthentication) return gClientCheckAuthentication(client);
#endif
    static dispatch_once_t once;
    static SecRequirementRef requirement;
    dispatch_once(&once, ^{
        SecRequirementCreateWithString(CFSTR(SONOFERRY_ENGINE_REQUIREMENT),
            kSecCSDefaultFlags, &requirement);
    });
    if (!requirement) return false;
    CFNumberRef pid = CFNumberCreate(NULL, kCFNumberIntType, &client);
    const void *keys[] = {kSecGuestAttributePid};
    const void *values[] = {pid};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    Boolean authorized = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCheckValidity(code, kSecCSStrictValidate, requirement) == errSecSuccess;
    if (code) CFRelease(code);
    CFRelease(attributes);
    CFRelease(pid);
    return authorized;
}

static void SonoFerryPriorityChanged(void) {
    AudioObjectPropertyAddress property = {kSonoFerryPriority, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    if (gPlugIn_Host) gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &property);
}

// Updated only on gLeaseQueue; readers take an immutable copy under StateMutex.
// No device address, publication UID, or unbounded XPC payload enters the log.
static void SonoFerryPriorityUpdateDiagnostics(void) {
    CFStringRef value = CFStringCreateWithFormat(NULL, NULL,
        CFSTR("bootstrap=%u events=%u matches=%u lastEvent=%lld listening=%d uid=%d sent=%d waiting=%lld"),
        gPriorityBootstrapCount, gPriorityEventCount, gPriorityMatchCount, (long long)gPriorityLastEvent,
        gPriorityListening, gPriorityUID != NULL, gPrioritySent, (long long)gPriorityWaiting);
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gPriorityDiagnostics) CFRelease(gPriorityDiagnostics);
    gPriorityDiagnostics = value;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
}

static void SonoFerryPriorityPhaseWithFailure(CFStringRef phase, CFStringRef error, CFStringRef code) {
    SonoFerryPriorityUpdateDiagnostics();
    pthread_mutex_lock(&gPlugIn_StateMutex);
    gPriorityPhase = phase;
    gPriorityError = error;
    gPriorityFailureCode = code;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    SonoFerryPriorityChanged();
}

static void SonoFerryPriorityPhase(CFStringRef phase, CFStringRef error) {
    SonoFerryPriorityPhaseWithFailure(phase, error, NULL);
}

static CFStringRef SonoFerryPriorityNormalize(CFStringRef address) {
    char text[18];
    if (!address || CFGetTypeID(address) != CFStringGetTypeID() || CFStringGetLength(address) != 17 ||
        !CFStringGetCString(address, text, sizeof(text), kCFStringEncodingASCII)) return NULL;
    for (size_t i = 0; i < 17; ++i) {
        if (i % 3 == 2) {
            if (text[i] != ':' && text[i] != '-') return NULL;
            text[i] = ':';
        } else {
            if (!isxdigit((unsigned char)text[i])) return NULL;
            text[i] = toupper((unsigned char)text[i]);
        }
    }
    return CFStringCreateWithCString(NULL, text, kCFStringEncodingASCII);
}

static xpc_object_t SonoFerryPriorityRequest(const char *uid, const char *address, int64_t status) {
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t args = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t unified = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(unified, "kBTAudioMsgUnifiedUSBCBTAddress", address);
    xpc_dictionary_set_int64(unified, "kBTAudioMsgUnifiedUSBCStatus", status);
    xpc_dictionary_set_value(args, "kBTAudioMsgUnifiedUSBCDict", unified);
    xpc_dictionary_set_int64(request, "kBTAudioMsgId", 3);
    xpc_dictionary_set_string(request, "kBTAudioMsgDeviceUid", uid);
    xpc_dictionary_set_value(request, "kBTAudioMsgArgs", args);
    xpc_release(unified);
    xpc_release(args);
    return request;
}

static void SonoFerryPriorityClose(void) {
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
    VOEnd(gPriorityConnectionGeneration, VO_END);
#endif
    gPriorityListening = false;
    gPriorityUIDAfterLoss = false;
    ++gPriorityConnectionGeneration;
    if (gPriorityConnection) {
        xpc_connection_cancel(gPriorityConnection);
        xpc_release(gPriorityConnection);
        gPriorityConnection = NULL;
    }
    if (gPriorityNotify >= 0) notify_cancel(gPriorityNotify);
    gPriorityNotify = -1;
    free(gPriorityUID);
    gPriorityUID = NULL;
    free(gPriorityRetiredUID);
    gPriorityRetiredUID = NULL;
    gPriorityPublicationWithdrawn = false;
    gPriorityWaiting = -1;
    gPriorityDeadline = 0;
    gPriorityRefreshAt = 0;
    gPriorityRefreshAttempts = 0;
}

static void SonoFerryPriorityUncertain(CFStringRef error) {
    gPriorityWaiting = -1;
    gPriorityDeadline = 0;
    gPriorityStopping = true;
    SonoFerryPriorityPhase(CFSTR("cleanup-required"), error);
}

static Boolean SonoFerryPriorityExpire(void) {
    if (!gPriorityDeadline || mach_absolute_time() < gPriorityDeadline) return false;
    Boolean publicationMissing = gPriorityEnabling && !gPriorityStopping && !gPrioritySent;
    if (gPrioritySent) gPriorityPublicationLost = true;
    SonoFerryPriorityClose();
    gPriorityStopping = true;
    SonoFerryPriorityPhaseWithFailure(CFSTR("cleanup-required"),
        publicationMissing ? CFSTR("Target audio publication was not available before the configuration deadline.")
            : CFSTR("Bluetooth configuration deadline expired; cleanup is uncertain."),
        publicationMissing ? CFSTR("publicationUnavailable") : NULL);
    return true;
}

static void SonoFerryPriorityIdle(void) {
    SonoFerryPriorityClose();
    gPrioritySent = false;
    gPriorityEnabling = false;
    gPriorityStopping = false;
    gPriorityDisconnected = false;
    gPriorityPublicationLost = false;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gPriorityAddress) CFRelease(gPriorityAddress);
    gPriorityAddress = NULL;
    gPriorityOwner = 0;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    SonoFerryPriorityPhase(CFSTR("idle"), NULL);
}

#ifdef SONOFERRY_PRIORITY_CHECK
static int64_t gPriorityCheckStatus = -1;
static UInt64 gPriorityCheckSends;
static UInt64 gPriorityCheckBootstraps;
#endif

static Boolean SonoFerryPrioritySend(int64_t status) {
    if (SonoFerryPriorityExpire() || !gPriorityUID) return false;
    int pending = 0;
#ifndef SONOFERRY_PRIORITY_CHECK
    if (!gPriorityConnection || gPriorityNotify < 0 ||
        notify_check(gPriorityNotify, &pending) != NOTIFY_STATUS_OK) {
        SonoFerryPriorityUncertain(CFSTR("Priority notification unavailable; cleanup is uncertain."));
        return false;
    }
#else
    (void)pending;
#endif
    char address[18];
    CFStringGetCString(gPriorityAddress, address, sizeof(address), kCFStringEncodingASCII);
    xpc_object_t request = SonoFerryPriorityRequest(gPriorityUID, address, status);
#ifndef SONOFERRY_PRIORITY_CHECK
    xpc_connection_send_message(gPriorityConnection, request);
#else
    gPriorityCheckStatus = status;
    ++gPriorityCheckSends;
#endif
    xpc_release(request);
    gPriorityWaiting = status;
    if (!gPriorityDeadline) gPriorityDeadline = mach_absolute_time() + (UInt64)(gTicksPerSecond * 40);
    if (status == 2) { gPrioritySent = true; gPriorityRefreshAt = 0; }
    SonoFerryPriorityUpdateDiagnostics();
    return true;
}

static void SonoFerryPriorityStop(void) {
    if (gPriorityWaiting == 2 && !gPriorityDisconnected) {
        gPriorityStopping = true;
        SonoFerryPriorityPhase(CFSTR("stopping"), NULL);
        return;
    }
    gPriorityStopping = true;
    if (!gPrioritySent) { SonoFerryPriorityIdle(); return; }
    SonoFerryPriorityPhase(gPriorityDisconnected ? CFSTR("cleanup-required") : CFSTR("stopping"), NULL);
    if (!gPriorityUID || (gPriorityPublicationLost && !gPriorityDisconnected)) {
        SonoFerryPriorityUncertain(CFSTR("Target publication was lost; confirm the old Bluetooth connection is disconnected."));
        return;
    }
    SonoFerryPrioritySend(gPriorityDisconnected ? 0 : 1);
}

static void SonoFerryPriorityNotification(void) {
    if (SonoFerryPriorityExpire()) return;
    int64_t status = gPriorityWaiting;
    if (status < 0) return;
    gPriorityWaiting = -1;
    if (status != 1) gPriorityDeadline = 0;
    if (status == 2) {
        if (gPriorityStopping) SonoFerryPriorityStop();
        else SonoFerryPriorityPhase(CFSTR("configured"), NULL);
    } else if (status == 1) {
        SonoFerryPrioritySend(0);
    } else if (status == 0) {
        SonoFerryPriorityIdle();
    }
}

static void SonoFerryPriorityEvent(xpc_object_t event) {
    if (SonoFerryPriorityExpire() || !gPriorityListening) return;
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
    VOObserve(event, gPriorityConnectionGeneration);
#endif
    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
        gPriorityListening = false;
        gPriorityUIDAfterLoss = false;
        if (gPrioritySent) gPriorityPublicationLost = true;
        free(gPriorityUID);
        gPriorityUID = NULL;
        free(gPriorityRetiredUID);
        gPriorityRetiredUID = NULL;
        gPriorityPublicationWithdrawn = false;
        SonoFerryPriorityUncertain(CFSTR("Audio-host connection was interrupted; cleanup is uncertain."));
        return;
    }
    if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    int64_t identifier = xpc_dictionary_get_int64(event, "kBTAudioMsgId");
    ++gPriorityEventCount; gPriorityLastEvent = identifier;
    SonoFerryPriorityUpdateDiagnostics();
    const char *uid = xpc_dictionary_get_string(event, "kBTAudioMsgDeviceUid");
    Boolean current = uid && gPriorityUID && !strcmp(uid, gPriorityUID);
    Boolean retired = uid && gPriorityRetiredUID && !strcmp(uid, gPriorityRetiredUID);
    if (identifier == 4 && (current || retired)) {
        Boolean confirmed = retired || !gPriorityPublicationLost || gPriorityUIDAfterLoss;
        free(gPriorityUID);
        gPriorityUID = NULL;
        free(gPriorityRetiredUID);
        gPriorityRetiredUID = NULL;
        gPriorityUIDAfterLoss = false;
        if (gPrioritySent) {
            gPriorityPublicationLost = true;
            gPriorityPublicationWithdrawn = confirmed;
            if (gPriorityDisconnected && confirmed) SonoFerryPriorityIdle();
            else SonoFerryPriorityUncertain(CFSTR("Target publication was withdrawn; cleanup is uncertain."));
        }
        return;
    }
    xpc_object_t args = xpc_dictionary_get_value(event, "kBTAudioMsgArgs");
    if (identifier != 2 || !uid || !args || xpc_get_type(args) != XPC_TYPE_DICTIONARY ||
        xpc_dictionary_get_int64(args, "kBTAudioMsgArgDeviceType") != 1952538980) return;
    xpc_object_t properties = xpc_dictionary_get_value(args, "kBTAudioMsgArgDeviceProperties");
    const char *address = properties && xpc_get_type(properties) == XPC_TYPE_DICTIONARY
        ? xpc_dictionary_get_string(properties, "kBTAudioMsgPropertyDeviceAddress") : NULL;
    if (!address) return;
    CFStringRef raw = CFStringCreateWithCString(NULL, address, kCFStringEncodingUTF8);
    CFStringRef normalized = SonoFerryPriorityNormalize(raw);
    if (raw) CFRelease(raw);
    Boolean matches = normalized && CFEqual(normalized, gPriorityAddress);
    if (normalized) CFRelease(normalized);
    if (!matches) return;
    ++gPriorityMatchCount;
    SonoFerryPriorityUpdateDiagnostics();
    if (gPriorityUID) {
        if (strcmp(gPriorityUID, uid)) {
            if (gPrioritySent) {
                gPriorityPublicationLost = true;
                gPriorityUIDAfterLoss = false;
                SonoFerryPriorityUncertain(CFSTR("More than one target audio publication; cleanup is uncertain."));
                return;
            }
            free(gPriorityUID);
            gPriorityUID = NULL;
        } else return;
    }
    gPriorityUID = strdup(uid);
    if (!gPriorityUID) {
        SonoFerryPriorityUncertain(CFSTR("Unable to retain the target audio publication."));
        return;
    }
    free(gPriorityRetiredUID);
    gPriorityRetiredUID = NULL;
    gPriorityPublicationWithdrawn = false;
    gPriorityUIDAfterLoss = gPrioritySent && gPriorityPublicationLost;
    if (gPrioritySent) {
        if (gPriorityDisconnected) SonoFerryPriorityStop();
        else SonoFerryPriorityUncertain(CFSTR("Target republished without confirmed old-link disconnect; cleanup is uncertain."));
    } else if (gPriorityEnabling && !gPriorityStopping) {
        SonoFerryPrioritySend(2);
    }
}

// The empty bootstrap is a read of published audio devices, not a priority write.
static void SonoFerryPriorityBootstrap(void) {
    ++gPriorityBootstrapCount;
    SonoFerryPriorityUpdateDiagnostics();
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
#ifndef SONOFERRY_PRIORITY_CHECK
    xpc_connection_send_message(gPriorityConnection, request);
#else
    assert(xpc_dictionary_get_count(request) == 0);
    ++gPriorityCheckBootstraps;
#endif
    xpc_release(request);
}

static void SonoFerryPriorityStart(void) {
#ifndef SONOFERRY_PRIORITY_CHECK
    if (notify_register_check("com.apple.bluetooth.AdaptiveJitterBufferChanged", &gPriorityNotify) != NOTIFY_STATUS_OK) {
        SonoFerryPriorityUncertain(CFSTR("Unable to observe the Bluetooth configuration notification."));
        return;
    }
    gPriorityConnection = xpc_connection_create_mach_service("com.apple.BTAudioHALPlugin.xpc", gLeaseQueue, 0);
    if (!gPriorityConnection) {
        SonoFerryPriorityUncertain(CFSTR("Unable to create the audio-host connection."));
        return;
    }
    UInt64 generation = ++gPriorityConnectionGeneration;
    xpc_connection_set_event_handler(gPriorityConnection, ^(xpc_object_t event) {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        Boolean shuttingDown = gShuttingDown;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        if (!shuttingDown && generation == gPriorityConnectionGeneration) {
            SonoFerryPriorityEvent(event);
            SonoFerryScheduleLeaseTimer();
        }
    });
    xpc_connection_resume(gPriorityConnection);
#endif
    gPriorityListening = true;
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
    VOBegin(gPriorityConnectionGeneration, gPriorityAddress, gTicksPerSecond);
#endif
    SonoFerryPriorityBootstrap();
}

static void SonoFerryPriorityTick(void) {
    SonoFerryPriorityExpire();
    if (gPriorityRefreshAt && mach_absolute_time() >= gPriorityRefreshAt &&
        gPriorityListening && gPriorityEnabling && !gPriorityStopping && !gPrioritySent && !gPriorityUID) {
        ++gPriorityRefreshAttempts;
        // Profile recreation can take longer than the old 2s/5s reads. Keep
        // bounded read-only discovery at 2s, 5s, 10s, 18s within the SAME deadline.
        static const UInt32 intervals[] = {3, 5, 8};
        gPriorityRefreshAt = gPriorityRefreshAttempts <= 3
            ? mach_absolute_time() + (UInt64)(gTicksPerSecond * intervals[gPriorityRefreshAttempts - 1]) : 0;
        SonoFerryPriorityBootstrap();
    }
    if (gPriorityWaiting >= 0 && gPriorityNotify >= 0) {
        int changed = 0;
        if (notify_check(gPriorityNotify, &changed) != NOTIFY_STATUS_OK)
            SonoFerryPriorityUncertain(CFSTR("Bluetooth notification observation failed; cleanup is uncertain."));
        else if (changed) SonoFerryPriorityNotification();
    }
    pthread_mutex_lock(&gPlugIn_StateMutex);
    Boolean ownerLost = gPriorityOwner && (gPriorityOwner != gLeaseOwner || !gLeaseDeadline ||
        mach_absolute_time() >= gLeaseDeadline);
    if (ownerLost) gPriorityOwner = 0;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (ownerLost) {
        if (!gPrioritySent) SonoFerryPriorityIdle();
        else {
            if (!gPriorityStopping) SonoFerryPriorityStop();
            SonoFerryPriorityPhase(CFSTR("cleanup-required"),
                CFSTR("Playback owner exited or released its lease; cleanup is uncertain."));
        }
    }
}

static void SonoFerryOwnerExited(pid_t owner, UInt64 generation) {
    pthread_mutex_lock(&gPlugIn_StateMutex);
    Boolean exited = !gShuttingDown && generation == gOwnerWatchGeneration && gLeaseOwner == owner;
    if (exited) {
        gLeaseDeadline = 0;
        gLeaseOwner = 0;
        gDesiredAvailable = false;
        ++gLeaseGeneration;
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (exited) { SonoFerryLeaseChanged(); SonoFerryRequestAvailability(); }
}

static void SonoFerryWatchOwner(pid_t owner) {
    if (owner == gWatchedOwner) return;
    ++gOwnerWatchGeneration;
    if (gOwnerWatcher) {
        dispatch_source_cancel(gOwnerWatcher);
        dispatch_release(gOwnerWatcher);
        gOwnerWatcher = NULL;
    }
    gWatchedOwner = owner;
#ifndef SONOFERRY_PRIORITY_CHECK
    if (!owner) return;
    gOwnerWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, owner, DISPATCH_PROC_EXIT, gLeaseQueue);
    if (!gOwnerWatcher) return;
    UInt64 generation = gOwnerWatchGeneration;
    dispatch_source_set_event_handler(gOwnerWatcher, ^{
        SonoFerryOwnerExited(owner, generation);
    });
    dispatch_resume(gOwnerWatcher);
#endif
}

static Boolean SonoFerrySupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < sizeof(gSampleRates) / sizeof(gSampleRates[0]); ++i)
        if (rate == gSampleRates[i]) return true;
    return false;
}

static Boolean SonoFerryObject(AudioObjectID object) {
    return object == kObjectID_PlugIn || object == kObjectID_Device ||
        object == kObjectID_Stream_Output || object == kObjectID_Volume_Output_Master ||
        object == kObjectID_Mute_Output_Master;
}

static Boolean SonoFerryAlive(void) {
    return atomic_load(&gAvailable);
}

static Boolean SonoFerryLeaseValid(void) {
    return gLeaseDeadline && mach_absolute_time() < gLeaseDeadline;
}

#include "SystemRateControl.inc"

static Boolean SonoFerryRefreshLease(void) {
    Boolean desired = SonoFerryLeaseValid();
    Boolean expired = gLeaseDeadline && !desired;
    if (expired) {
        gLeaseDeadline = 0;
        gLeaseOwner = 0;
    }
    if (desired != gDesiredAvailable) {
        gDesiredAvailable = desired;
        ++gLeaseGeneration;
    }
    return expired;
}

static void SonoFerryLeaseChanged(void) {
    AudioObjectPropertyAddress property = {kSonoFerryLease, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &property);
}

static void SonoFerryScheduleLeaseTimer(void) {
    pthread_mutex_lock(&gPlugIn_StateMutex);
    Boolean needed = !gShuttingDown && (gLeaseDeadline || gPendingAction || gPendingRateAction ||
        gDesiredAvailable != SonoFerryAlive() || gPriorityWaiting >= 0 || gPriorityDeadline);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (needed == gLeaseTimerArmed) return;
    gLeaseTimerArmed = needed;
    dispatch_source_set_timer(gLeaseTimer, needed ? dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)
        : DISPATCH_TIME_FOREVER, 250 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
}

static void SonoFerryRequestAvailability(void) {
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gShuttingDown) { pthread_mutex_unlock(&gPlugIn_StateMutex); return; }
    Boolean expired = SonoFerryRefreshLease();
    UInt64 action = 0;
    if (!gPendingAction && gDesiredAvailable != SonoFerryAlive()) {
        action = gPendingAction = ++gNextAction;
        gPendingGeneration = gLeaseGeneration;
        gPendingAvailable = gDesiredAvailable;
    }
    pid_t owner = gLeaseOwner;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    SonoFerryWatchOwner(owner);
    SonoFerryPriorityTick();
    if (expired) SonoFerryLeaseChanged();
    if (action && gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, action, NULL)) {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        if (gPendingAction == action) gPendingAction = 0;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
    }
    SonoFerryScheduleLeaseTimer();
}

static void SonoFerryQueueAvailability(void) {
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (!gShuttingDown) dispatch_async(gLeaseQueue, ^{ SonoFerryRequestAvailability(); });
    pthread_mutex_unlock(&gPlugIn_StateMutex);
}

static OSStatus SonoFerryPerformConfiguration(AudioServerPlugInDriverRef driver, AudioObjectID device,
                                        UInt64 action, void *info) {
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    Boolean expired = SonoFerryRefreshLease();
    Boolean changed = false;
    if (!gShuttingDown && action == gPendingAction && action) {
        if (gPendingGeneration == gLeaseGeneration && gPendingAvailable == gDesiredAvailable) {
            changed = SonoFerryAlive() != gPendingAvailable;
            atomic_store(&gAvailable, gPendingAvailable);
        }
        gPendingAction = 0;
    }
    if (!gShuttingDown && action && action == gPendingRateAction) {
        if (gPendingRateOwner == gLeaseOwner && SonoFerryLeaseValid() &&
            gPendingRateGeneration == gLeaseGeneration && !gDevice_IOIsRunning) {
            gDevice_SampleRate = gPendingRate;
            gDevice_HostTicksPerFrame = gTicksPerSecond / gDevice_SampleRate;
            gDevice_NumberTimeStamps = 0;
            gDevice_AnchorSampleTime = 0;
            gDevice_AnchorHostTime = mach_absolute_time();
            atomic_store(&gClockPeriod, (UInt32)ceil(kDevice_RingBufferSize * gDevice_SampleRate / 48000));
            atomic_store(&gClockTicksPerFrame, gDevice_HostTicksPerFrame);
            atomic_store(&gClockAnchor, gDevice_AnchorHostTime);
            atomic_fetch_add(&gClockSeed, 1);
        }
        gPendingRateAction = 0;
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (expired || changed) SonoFerryLeaseChanged();
    SonoFerryQueueAvailability();
    return noErr;
}

static OSStatus SonoFerryAbortConfiguration(AudioServerPlugInDriverRef driver, AudioObjectID device,
                                      UInt64 action, void *info) {
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (action == gPendingAction) gPendingAction = 0;
    if (action == gPendingRateAction) gPendingRateAction = 0;
    if (!gShuttingDown) dispatch_async(gLeaseQueue, ^{ SonoFerryScheduleLeaseTimer(); });
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return noErr;
}

static OSStatus SonoFerryInitialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    gDevice_SampleRate = 48000;
    gVolume_Output_Master_Value = 0;
    gMute_Output_Master_Value = true;
    OSStatus status = NullAudio_Initialize(driver, host);
    if (status) return status;
    gShuttingDown = false;
    gLeaseDeadline = 0;
    gLeaseOwner = 0;
    gDesiredAvailable = false;
    gPendingAction = 0;
    atomic_store(&gAvailable, false);
    gModel = CFRetain(CFSTR("Headphones"));
    gTicksPerSecond = gDevice_HostTicksPerFrame * 48000;
    gPendingRateAction = 0;
    gSystemRateEnabled = false;
    gSystemRateMask = 0;
    gSystemRequestedRate = 0;
    gPriorityPhase = gPrioritySent ? CFSTR("cleanup-required") : CFSTR("idle");
    gPriorityFailureCode = NULL;
    gPriorityRefreshAt = 0;
    gPriorityRefreshAttempts = 0;
    gPriorityOwner = 0;
    atomic_store(&gClockPeriod, kDevice_RingBufferSize);
    atomic_store(&gClockTicksPerFrame, gDevice_HostTicksPerFrame);
    atomic_store(&gClockAnchor, mach_absolute_time());
    atomic_store(&gClockSeed, 1);
    gLeaseQueue = dispatch_queue_create("local.SonoFerry.output-lease", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(gLeaseQueue, &gLeaseQueueKey, &gLeaseQueueKey, NULL);
    gLeaseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gLeaseQueue);
    if (!gLeaseTimer) {
        dispatch_release(gLeaseQueue);
        gLeaseQueue = NULL;
        CFRelease(gModel);
        gModel = NULL;
        return kAudioHardwareUnspecifiedError;
    }
    gLeaseTimerArmed = false;
    dispatch_source_set_timer(gLeaseTimer, DISPATCH_TIME_FOREVER, 250 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gLeaseTimer, ^{ SonoFerryRequestAvailability(); });
    dispatch_resume(gLeaseTimer);
    return noErr;
}

static ULONG SonoFerryRelease(void *driver) {
    ULONG references = NullAudio_Release(driver);
    if (!references && gLeaseTimer) {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        gShuttingDown = true;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        dispatch_source_cancel(gLeaseTimer);
        dispatch_block_t shutdown = ^{
            if (gPrioritySent) {
                if (gPriorityWaiting != 0 && gPriorityWaiting != 1 && gPriorityUID &&
                    (!gPriorityPublicationLost || gPriorityDisconnected))
                    SonoFerryPrioritySend(gPriorityDisconnected ? 0 : 1);
                SonoFerryPriorityPhase(CFSTR("cleanup-required"),
                    CFSTR("Audio host released before cleanup notification; cleanup is uncertain."));
            } else SonoFerryPriorityIdle();
            SonoFerryPriorityClose();
            SonoFerryWatchOwner(0);
        };
        if (dispatch_get_specific(&gLeaseQueueKey)) shutdown();
        else dispatch_sync(gLeaseQueue, shutdown);
        dispatch_release(gLeaseTimer);
        dispatch_release(gLeaseQueue);
        gLeaseTimer = NULL;
        gLeaseTimerArmed = false;
        gLeaseQueue = NULL;
        gLeaseDeadline = 0;
        gLeaseOwner = 0;
        gPendingAction = 0;
        gPendingRateAction = 0;
        atomic_store(&gAvailable, false);
        CFRelease(gModel);
        gModel = NULL;
        gPlugIn_Host = NULL;
    }
    return references;
}

static AudioObjectID SonoFerry(AudioObjectID object, const AudioObjectPropertyAddress *property,
                                AudioObjectPropertyAddress *controlProperty) {
    if (object != kObjectID_Device || property->mScope != kAudioObjectPropertyScopeOutput ||
        property->mElement != kAudioObjectPropertyElementMain) return kAudioObjectUnknown;
    *controlProperty = (AudioObjectPropertyAddress){0, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    switch (property->mSelector) {
        case kAudioDevicePropertyVolumeScalar:
            controlProperty->mSelector = kAudioLevelControlPropertyScalarValue;
            return kObjectID_Volume_Output_Master;
        case kAudioDevicePropertyMute:
            controlProperty->mSelector = kAudioBooleanControlPropertyValue;
            return kObjectID_Mute_Output_Master;
    }
    return kAudioObjectUnknown;
}

static UInt32 SonoFerryList(AudioObjectID object, const AudioObjectPropertyAddress *property,
                       AudioObjectID values[3]) {
    if (object == kObjectID_PlugIn) {
        if (property->mSelector == kAudioPlugInPropertyBoxList ||
            property->mSelector == kAudioObjectPropertyCustomPropertyInfoList) return 0;
        if (property->mSelector == kAudioObjectPropertyOwnedObjects ||
            property->mSelector == kAudioPlugInPropertyDeviceList) {
            values[0] = kObjectID_Device;
            return 1;
        }
    }
    if (object == kObjectID_Device) {
        if (property->mSelector == kAudioObjectPropertyOwnedObjects ||
            property->mSelector == kAudioDevicePropertyStreams ||
            property->mSelector == kAudioObjectPropertyControlList) {
            if (property->mScope == kAudioObjectPropertyScopeInput) return 0;
            UInt32 count = 0;
            if (property->mSelector != kAudioObjectPropertyControlList) values[count++] = kObjectID_Stream_Output;
            if (property->mSelector != kAudioDevicePropertyStreams) {
                values[count++] = kObjectID_Volume_Output_Master;
                values[count++] = kObjectID_Mute_Output_Master;
            }
            return count;
        }
    }
    return UINT32_MAX;
}

static UInt32 SonoFerrySize(AudioObjectID object, const AudioObjectPropertyAddress *property) {
    if (object == kObjectID_PlugIn && property->mSelector == kAudioPlugInPropertyBundleID)
        return sizeof(CFStringRef);
    AudioObjectID values[3];
    UInt32 count = SonoFerryList(object, property, values);
    if (count != UINT32_MAX) return count * sizeof(AudioObjectID);
    if (object == kObjectID_Device) {
        switch (property->mSelector) {
            case kSonoFerryLease: return sizeof(CFBooleanRef);
            case kSonoFerryModel: return sizeof(CFStringRef);
            case kAudioDevicePropertyIcon: return sizeof(CFURLRef);
            case kSonoFerryPriority: return sizeof(CFPropertyListRef);
            case kSonoFerryRevision: return sizeof(CFNumberRef);
            case kSonoFerryEngineIdentity: return sizeof(CFStringRef);
            case kSonoFerryRateControl: return sizeof(CFPropertyListRef);
            case kAudioDevicePropertyVolumeScalar: return sizeof(Float32);
            case kAudioDevicePropertyMute: return sizeof(UInt32);
            case kAudioObjectPropertyCustomPropertyInfoList: return SONOFERRY_CUSTOM_PROPERTY_COUNT * sizeof(AudioServerPlugInCustomPropertyInfo);
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
            case kSonoFerryVolumeObservation: return sizeof(CFPropertyListRef);
#endif
            case kAudioDevicePropertyAvailableNominalSampleRates: return SonoFerryCurrentRates(NULL) * sizeof(AudioValueRange);
        }
    }
    if (object == kObjectID_Stream_Output &&
        (property->mSelector == kAudioStreamPropertyAvailableVirtualFormats ||
         property->mSelector == kAudioStreamPropertyAvailablePhysicalFormats))
        return SonoFerryCurrentRates(NULL) * sizeof(AudioStreamRangedDescription);
    if (object == kObjectID_Stream_Output && property->mSelector == kAudioStreamPropertyTerminalType)
        return sizeof(UInt32);
    return UINT32_MAX;
}

static Boolean SonoFerryHasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                              const AudioObjectPropertyAddress *property) {
    if (driver != gAudioServerPlugInDriverRef || !SonoFerryObject(object) || !property) return false;
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
    if (property->mSelector == kSonoFerryVolumeObservation)
        return object == kObjectID_Device && property->mScope == kAudioObjectPropertyScopeGlobal &&
            property->mElement == kAudioObjectPropertyElementMain;
#endif
    AudioObjectPropertyAddress controlProperty;
    if (SonoFerry(object, property, &controlProperty)) return true;
    if (property->mSelector == kAudioDevicePropertyIcon)
        return object == kObjectID_Device && property->mScope == kAudioObjectPropertyScopeGlobal &&
            property->mElement == kAudioObjectPropertyElementMain;
    if (object == kObjectID_PlugIn && property->mSelector == kAudioPlugInPropertyBundleID)
        return property->mScope == kAudioObjectPropertyScopeGlobal &&
            property->mElement == kAudioObjectPropertyElementMain;
    if (property->mSelector == kPlugIn_CustomPropertyID ||
        (object == kObjectID_PlugIn && property->mSelector == kAudioPlugInPropertyTranslateUIDToBox))
        return false;
    if (object == kObjectID_Device && (property->mSelector == kSonoFerryLease || property->mSelector == kSonoFerryModel ||
        property->mSelector == kSonoFerryPriority || property->mSelector == kSonoFerryEngineIdentity || property->mSelector == kSonoFerryRevision || property->mSelector == kSonoFerryRateControl ||
        property->mSelector == kAudioObjectPropertyCustomPropertyInfoList))
        return property->mScope == kAudioObjectPropertyScopeGlobal && property->mElement == kAudioObjectPropertyElementMain;
    return NullAudio_HasProperty(driver, object, client, property);
}

static OSStatus SonoFerryIsSettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                              const AudioObjectPropertyAddress *property, Boolean *settable) {
    if (!SonoFerryHasProperty(driver, object, client, property)) return kAudioHardwareUnknownPropertyError;
    if (!settable) return kAudioHardwareIllegalOperationError;
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
    if (property->mSelector == kSonoFerryVolumeObservation) { *settable = false; return noErr; }
#endif
    AudioObjectPropertyAddress controlProperty;
    if (SonoFerry(object, property, &controlProperty) ||
        (object == kObjectID_Device && (property->mSelector == kSonoFerryLease || property->mSelector == kSonoFerryModel ||
            property->mSelector == kSonoFerryPriority || property->mSelector == kSonoFerryRateControl))) {
        *settable = true;
        return noErr;
    }
    if (property->mSelector == kAudioObjectPropertyCustomPropertyInfoList || property->mSelector == kSonoFerryEngineIdentity || property->mSelector == kSonoFerryRevision ||
        (object == kObjectID_PlugIn && property->mSelector == kAudioPlugInPropertyBundleID)) {
        *settable = false;
        return noErr;
    }
    return NullAudio_IsPropertySettable(driver, object, client, property, settable);
}

static OSStatus SonoFerryGetSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                           const AudioObjectPropertyAddress *property, UInt32 qualifierSize,
                           const void *qualifier, UInt32 *size) {
    if (!SonoFerryHasProperty(driver, object, client, property)) return kAudioHardwareUnknownPropertyError;
    if (!size) return kAudioHardwareIllegalOperationError;
    UInt32 custom = SonoFerrySize(object, property);
    if (custom != UINT32_MAX) { *size = custom; return noErr; }
    return NullAudio_GetPropertyDataSize(driver, object, client, property, qualifierSize, qualifier, size);
}

static OSStatus SonoFerryGetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                           const AudioObjectPropertyAddress *property, UInt32 qualifierSize,
                           const void *qualifier, UInt32 capacity, UInt32 *size, void *data) {
    if (!SonoFerryHasProperty(driver, object, client, property)) return kAudioHardwareUnknownPropertyError;
    if (!size || (!data && capacity)) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertyAddress controlProperty;
    AudioObjectID control = SonoFerry(object, property, &controlProperty);
    if (control) return SonoFerryGetData(driver, control, client, &controlProperty, qualifierSize,
                                   qualifier, capacity, size, data);
    AudioObjectID values[3];
    UInt32 count = SonoFerryList(object, property, values);
    if (count != UINT32_MAX) {
        UInt32 requested = capacity / sizeof(AudioObjectID);
        *size = (requested < count ? requested : count) * sizeof(AudioObjectID);
        if (*size) memcpy(data, values, *size);
        return noErr;
    }
    UInt32 custom = SonoFerrySize(object, property);
    Boolean rateList = (object == kObjectID_Device && property->mSelector == kAudioDevicePropertyAvailableNominalSampleRates) ||
        (object == kObjectID_Stream_Output && (property->mSelector == kAudioStreamPropertyAvailableVirtualFormats ||
         property->mSelector == kAudioStreamPropertyAvailablePhysicalFormats));
    if (custom != UINT32_MAX && capacity < custom && !rateList) return kAudioHardwareBadPropertySizeError;
    if (object == kObjectID_Stream_Output && property->mSelector == kAudioStreamPropertyTerminalType) {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        *(UInt32 *)data = SonoFerryTerminalType(gModel);
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *size = sizeof(UInt32);
        return noErr;
    }
    if (property->mSelector == kAudioObjectPropertyManufacturer) {
        if (capacity < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        *(CFStringRef *)data = CFRetain(CFSTR("SonoFerry"));
        *size = sizeof(CFStringRef);
        return noErr;
    }
    if (object == kObjectID_PlugIn && property->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) {
        if (qualifierSize != sizeof(CFStringRef) || !qualifier || capacity < sizeof(AudioObjectID))
            return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(const CFStringRef *)qualifier;
        if (!uid || CFGetTypeID(uid) != CFStringGetTypeID()) return kAudioHardwareIllegalOperationError;
        *(AudioObjectID *)data = CFEqual(uid, CFSTR("local.SonoFerry.ldac-output"))
            ? kObjectID_Device : kAudioObjectUnknown;
        *size = sizeof(AudioObjectID);
        return noErr;
    }
    if (object == kObjectID_PlugIn && property->mSelector == kAudioPlugInPropertyBundleID) {
        if (capacity < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        *(CFStringRef *)data = CFRetain(CFSTR("local.SonoFerry.LDACOutput"));
        *size = sizeof(CFStringRef);
        return noErr;
    }
    if (object == kObjectID_Device) {
        switch (property->mSelector) {
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
            case kSonoFerryVolumeObservation:
                *(CFPropertyListRef *)data = VOCopySnapshot();
                if (!*(CFPropertyListRef *)data) return kAudioHardwareUnspecifiedError;
                *size = sizeof(CFPropertyListRef);
                return noErr;
#endif
            case kAudioDevicePropertyIcon: {
                CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("local.SonoFerry.LDACOutput"));
                if (!bundle) return kAudioHardwareUnspecifiedError;
                pthread_mutex_lock(&gPlugIn_StateMutex);
                CFStringRef name = SonoFerryIconName(gModel);
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                CFURLRef url = CFBundleCopyResourceURL(bundle, name, CFSTR("png"), NULL);
                if (!url) return kAudioHardwareUnspecifiedError;
                *(CFURLRef *)data = url;
                *size = sizeof(CFURLRef);
                return noErr;
            }
            case kSonoFerryLease: {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Boolean ownsLease = client == gLeaseOwner && SonoFerryLeaseValid();
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                Boolean authorized = ownsLease && SonoFerryClientAuthorized(client);
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *(CFBooleanRef *)data = CFRetain(authorized && client == gLeaseOwner && SonoFerryLeaseValid()
                    ? kCFBooleanTrue : kCFBooleanFalse);
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                *size = sizeof(CFBooleanRef);
                return noErr;
            }
            case kSonoFerryEngineIdentity:
                *(CFStringRef *)data = CFRetain(CFSTR(SONOFERRY_ENGINE_CDHASH));
                *size = sizeof(CFStringRef);
                return noErr;
            case kSonoFerryRevision:
                *(CFNumberRef *)data = CFNumberCreate(NULL, kCFNumberSInt32Type, &kSonoFerryDriverRevision);
                *size = sizeof(CFNumberRef);
                return noErr;
            case kSonoFerryRateControl:
                *(CFPropertyListRef *)data = SonoFerryCopyRateControl();
                *size = sizeof(CFPropertyListRef);
                return noErr;
            case kSonoFerryModel:
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *(CFStringRef *)data = CFRetain(gModel);
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                *size = sizeof(CFStringRef);
                return noErr;
            case kSonoFerryPriority: {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                Boolean ownsLease = client == gLeaseOwner && SonoFerryLeaseValid();
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                Boolean authorized = ownsLease && SonoFerryClientAuthorized(client);
                CFMutableDictionaryRef result = CFDictionaryCreateMutable(NULL, 0,
                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                pthread_mutex_lock(&gPlugIn_StateMutex);
                CFDictionarySetValue(result, CFSTR("phase"), gPriorityPhase);
                if (authorized && client == gLeaseOwner && SonoFerryLeaseValid()) {
                    if (gPriorityAddress) CFDictionarySetValue(result, CFSTR("address"), gPriorityAddress);
                    if (gPriorityError) CFDictionarySetValue(result, CFSTR("error"), gPriorityError);
                    if (gPriorityFailureCode) CFDictionarySetValue(result, CFSTR("failureCode"), gPriorityFailureCode);
                    if (gPriorityDiagnostics) CFDictionarySetValue(result, CFSTR("diagnostics"), gPriorityDiagnostics);
                }
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                *(CFPropertyListRef *)data = result;
                *size = sizeof(CFPropertyListRef);
                return noErr;
            }
            case kAudioObjectPropertyCustomPropertyInfoList:
                ((AudioServerPlugInCustomPropertyInfo *)data)[0] = (AudioServerPlugInCustomPropertyInfo){
                    kSonoFerryLease, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone};
                ((AudioServerPlugInCustomPropertyInfo *)data)[1] = (AudioServerPlugInCustomPropertyInfo){
                    kSonoFerryModel, kAudioServerPlugInCustomPropertyDataTypeCFString,
                    kAudioServerPlugInCustomPropertyDataTypeNone};
                ((AudioServerPlugInCustomPropertyInfo *)data)[2] = (AudioServerPlugInCustomPropertyInfo){
                    kSonoFerryPriority, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone};
                ((AudioServerPlugInCustomPropertyInfo *)data)[3] = (AudioServerPlugInCustomPropertyInfo){
                    kSonoFerryRevision, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone};
                ((AudioServerPlugInCustomPropertyInfo *)data)[4] = (AudioServerPlugInCustomPropertyInfo){
                    kSonoFerryRateControl, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone};
                ((AudioServerPlugInCustomPropertyInfo *)data)[5] = (AudioServerPlugInCustomPropertyInfo){
                    kSonoFerryEngineIdentity, kAudioServerPlugInCustomPropertyDataTypeCFString,
                    kAudioServerPlugInCustomPropertyDataTypeNone};
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
                ((AudioServerPlugInCustomPropertyInfo *)data)[6] = (AudioServerPlugInCustomPropertyInfo){
                    kSonoFerryVolumeObservation, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone};
#endif
                *size = SONOFERRY_CUSTOM_PROPERTY_COUNT * sizeof(AudioServerPlugInCustomPropertyInfo);
                return noErr;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                Float64 rates[SONOFERRY_RATE_COUNT]; UInt32 count = SonoFerryCurrentRates(rates);
                *size = (capacity / sizeof(AudioValueRange) < count ? capacity / sizeof(AudioValueRange) : count) * sizeof(AudioValueRange);
                for (UInt32 i = 0; i < *size / sizeof(AudioValueRange); ++i)
                    ((AudioValueRange *)data)[i] = (AudioValueRange){rates[i], rates[i]};
                return noErr;
            }
            case kAudioDevicePropertyZeroTimeStampPeriod:
                if (capacity < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)data = atomic_load(&gClockPeriod);
                *size = sizeof(UInt32);
                return noErr;
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (capacity < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)data = SonoFerryAlive() && property->mScope != kAudioObjectPropertyScopeInput;
                *size = sizeof(UInt32);
                return noErr;
            case kAudioDevicePropertyIsHidden:
                if (capacity < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                *(UInt32 *)data = !SonoFerryAlive();
                *size = sizeof(UInt32);
                return noErr;
            case kAudioObjectPropertyName:
                if (capacity < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                pthread_mutex_lock(&gPlugIn_StateMutex);
                *(CFStringRef *)data = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ · SonoFerry"), gModel);
                pthread_mutex_unlock(&gPlugIn_StateMutex);
                *size = sizeof(CFStringRef);
                return noErr;
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                if (capacity < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
                *(CFStringRef *)data = CFRetain(CFSTR("local.SonoFerry.ldac-output"));
                *size = sizeof(CFStringRef);
                return noErr;
        }
    }
    if (object == kObjectID_Stream_Output && (property->mSelector == kAudioStreamPropertyVirtualFormat ||
        property->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (capacity < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&gPlugIn_StateMutex);
        *(AudioStreamBasicDescription *)data = (AudioStreamBasicDescription){gDevice_SampleRate,
            kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0};
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *size = sizeof(AudioStreamBasicDescription);
        return noErr;
    }
    if (object == kObjectID_Stream_Output && rateList) {
        Float64 rates[SONOFERRY_RATE_COUNT]; UInt32 count = SonoFerryCurrentRates(rates);
        *size = (capacity / sizeof(AudioStreamRangedDescription) < count ? capacity / sizeof(AudioStreamRangedDescription) : count) * sizeof(AudioStreamRangedDescription);
        for (UInt32 i = 0; i < *size / sizeof(AudioStreamRangedDescription); ++i)
            ((AudioStreamRangedDescription *)data)[i] = (AudioStreamRangedDescription){
                {rates[i], kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                 8, 1, 8, 2, 32, 0}, {rates[i], rates[i]}};
        return noErr;
    }
    return NullAudio_GetPropertyData(driver, object, client, property, qualifierSize, qualifier, capacity, size, data);
}

static OSStatus SonoFerrySetRate(pid_t client, Float64 rate) {
    if (!SonoFerrySupportedRate(rate)) return kAudioDeviceUnsupportedFormatError;
    Boolean handled = false;
    OSStatus request = SonoFerryRequestSystemRate(client, rate, &handled);
    if (handled) return request;
    Boolean authorized = SonoFerryClientAuthorized(client);
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (!gPendingRateAction && rate == gDevice_SampleRate) {
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        return noErr;
    }
    if (!authorized || gLeaseOwner != client || !SonoFerryLeaseValid()) {
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        return kAudioDevicePermissionsError;
    }
    if (gDevice_IOIsRunning || gShuttingDown || (gPendingRateAction && rate != gPendingRate)) {
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (gPendingRateAction || rate == gDevice_SampleRate) {
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        return noErr;
    }
    UInt64 action = gPendingRateAction = ++gNextAction;
    gPendingRate = rate;
    gPendingRateOwner = client;
    gPendingRateGeneration = gLeaseGeneration;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    dispatch_async(gLeaseQueue, ^{
        if (gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, action, NULL)) {
            pthread_mutex_lock(&gPlugIn_StateMutex);
            if (gPendingRateAction == action) gPendingRateAction = 0;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
        }
        SonoFerryScheduleLeaseTimer();
    });
    return noErr;
}

static OSStatus SonoFerrySetPriority(pid_t client, CFPropertyListRef value) {
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) return kAudioHardwareIllegalOperationError;
    CFDictionaryRef request = (CFDictionaryRef)value;
    CFTypeRef enabled = CFDictionaryGetValue(request, CFSTR("enabled"));
    CFTypeRef disconnected = CFDictionaryGetValue(request, CFSTR("disconnected"));
    CFTypeRef prepare = CFDictionaryGetValue(request, CFSTR("prepare"));
    CFStringRef address = SonoFerryPriorityNormalize(CFDictionaryGetValue(request, CFSTR("address")));
    if (!address || !enabled || CFGetTypeID(enabled) != CFBooleanGetTypeID() ||
        CFDictionaryGetCount(request) != (disconnected || prepare ? 3 : 2) ||
        (disconnected && (CFGetTypeID(disconnected) != CFBooleanGetTypeID() || CFBooleanGetValue(enabled))) ||
        (prepare && (CFGetTypeID(prepare) != CFBooleanGetTypeID() || !CFBooleanGetValue(prepare) ||
            CFBooleanGetValue(enabled) || disconnected))) {
        if (address) CFRelease(address);
        return kAudioHardwareIllegalOperationError;
    }
    Boolean enable = CFBooleanGetValue(enabled);
    Boolean observe = prepare != NULL;
    Boolean oldLinkDisconnected = disconnected && CFBooleanGetValue(disconnected);
    pthread_mutex_lock(&gPlugIn_StateMutex);
    dispatch_queue_t queue = !gShuttingDown ? gLeaseQueue : NULL;
    if (queue) dispatch_retain(queue);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (!queue) { CFRelease(address); return kAudioHardwareIllegalOperationError; }
    __block OSStatus status = noErr;
    dispatch_block_t apply = ^{
        if (!SonoFerryClientAuthorized(client)) { status = kAudioDevicePermissionsError; return; }
        SonoFerryPriorityExpire();
        pthread_mutex_lock(&gPlugIn_StateMutex);
        if (gShuttingDown) status = kAudioHardwareIllegalOperationError;
        else if (gLeaseOwner != client || !SonoFerryLeaseValid()) status = kAudioDevicePermissionsError;
        else if (gPriorityAddress && !CFEqual(gPriorityAddress, address)) status = kAudioHardwareIllegalOperationError;
        else if ((enable || observe) && gPriorityAddress && (gPriorityOwner != client || gPriorityStopping ||
            (observe && gPriorityEnabling)))
            status = kAudioHardwareIllegalOperationError;
        Boolean repeat = gPriorityAddress != NULL;
        if (!status && (enable || observe) && !repeat) {
            gPriorityBootstrapCount = gPriorityEventCount = gPriorityMatchCount = 0;
            gPriorityLastEvent = 0;
            gPriorityAddress = CFRetain(address);
            gPriorityOwner = client;
            gPriorityPhase = observe ? CFSTR("observing") : CFSTR("configuring");
            gPriorityError = NULL;
        }
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        if (status) return;
        if (observe) {
            if (!repeat) { SonoFerryPriorityChanged(); SonoFerryPriorityStart(); }
        } else if (enable) {
            if (!gPriorityEnabling) {
                gPriorityEnabling = true;
                gPriorityDeadline = mach_absolute_time() + (UInt64)(gTicksPerSecond * 40);
                SonoFerryPriorityPhase(CFSTR("configuring"), NULL);
                if (!repeat) SonoFerryPriorityStart();
                if (gPriorityUID && !gPriorityStopping) SonoFerryPrioritySend(2);
                else if (gPriorityListening && !gPriorityStopping) {
                    gPriorityRefreshAttempts = 0;
                    gPriorityRefreshAt = mach_absolute_time() + (UInt64)(gTicksPerSecond * 2);
                }
            }
        } else if (!gPrioritySent) {
            SonoFerryPriorityIdle();
        } else if (oldLinkDisconnected && (!gPriorityDisconnected || (gPriorityWaiting < 0 && !gPriorityUID))) {
            gPriorityDisconnected = true;
            gPriorityStopping = true;
            if (gPriorityPublicationWithdrawn && gPriorityListening && !gPriorityUID) {
                SonoFerryPriorityIdle();
                return;
            }
            if (!gPriorityUIDAfterLoss && gPriorityUID) {
                free(gPriorityRetiredUID);
                gPriorityRetiredUID = !gPriorityPublicationLost ? gPriorityUID : NULL;
                if (gPriorityPublicationLost) free(gPriorityUID);
                gPriorityUID = NULL;
            }
            gPriorityPublicationLost = true;
            gPriorityWaiting = -1;
            gPriorityDeadline = mach_absolute_time() + (UInt64)(gTicksPerSecond * 40);
            SonoFerryPriorityPhase(CFSTR("cleanup-required"), NULL);
            if (!gPriorityListening) {
                SonoFerryPriorityClose();
                gPriorityDeadline = mach_absolute_time() + (UInt64)(gTicksPerSecond * 40);
                SonoFerryPriorityStart();
            } else if (gPriorityUID) SonoFerryPrioritySend(0);
        } else if (gPriorityWaiting != 1 && gPriorityWaiting != 0 &&
            (!gPriorityDisconnected || gPriorityUID)) {
            SonoFerryPriorityStop();
        }
    };
    dispatch_block_t update = ^{ apply(); SonoFerryScheduleLeaseTimer(); };
    if (dispatch_get_specific(&gLeaseQueueKey)) update();
    else dispatch_sync(queue, update);
    dispatch_release(queue);
    CFRelease(address);
    return status;
}

static OSStatus SonoFerrySetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t client,
                           const AudioObjectPropertyAddress *property, UInt32 qualifierSize,
                           const void *qualifier, UInt32 size, const void *data) {
    if (!SonoFerryHasProperty(driver, object, client, property)) return kAudioHardwareUnknownPropertyError;
#ifdef SONOFERRY_VOLUME_DIAGNOSTICS
    if (property->mSelector == kSonoFerryVolumeObservation) return kAudioHardwareIllegalOperationError;
#endif
    if (!data) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertyAddress controlProperty;
    AudioObjectID control = SonoFerry(object, property, &controlProperty);
    if (control) return SonoFerrySetData(driver, control, client, &controlProperty, qualifierSize, qualifier, size, data);
    if (object == kObjectID_Device && property->mSelector == kSonoFerryPriority) {
        if (size != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
        return SonoFerrySetPriority(client, *(const CFPropertyListRef *)data);
    }
    if (object == kObjectID_Device && property->mSelector == kSonoFerryRateControl) {
        if (size != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
        return SonoFerrySetRateControl(client, *(const CFPropertyListRef *)data);
    }
    if (object == kObjectID_Device && property->mSelector == kSonoFerryLease) {
        if (size != sizeof(CFDictionaryRef)) return kAudioHardwareBadPropertySizeError;
        CFDictionaryRef request = *(const CFDictionaryRef *)data;
        if (!request || CFGetTypeID(request) != CFDictionaryGetTypeID() || CFDictionaryGetCount(request) != 1)
            return kAudioHardwareIllegalOperationError;
        CFBooleanRef renew = CFDictionaryGetValue(request, CFSTR("claim"));
        if (!renew || CFGetTypeID(renew) != CFBooleanGetTypeID() || client <= 0)
            return kAudioHardwareIllegalOperationError;
        if (!SonoFerryClientAuthorized(client)) return kAudioDevicePermissionsError;
        pthread_mutex_lock(&gPlugIn_StateMutex);
        SonoFerryRefreshLease();
        Boolean claim = CFBooleanGetValue(renew);
        if ((!claim && gLeaseOwner != client) || (gLeaseOwner && gLeaseOwner != client)) {
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            return kAudioDevicePermissionsError;
        }
        gLeaseOwner = claim ? client : 0;
        gLeaseDeadline = claim ? mach_absolute_time() + (UInt64)(gTicksPerSecond * 3) : 0;
        SonoFerryRefreshLease();
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        SonoFerryLeaseChanged();
        SonoFerryQueueAvailability();
        return noErr;
    }
    if (object == kObjectID_Device && property->mSelector == kSonoFerryModel) {
        if (size != sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
        CFStringRef model = *(const CFStringRef *)data;
        if (!model || CFGetTypeID(model) != CFStringGetTypeID() ||
            CFStringGetLength(model) == 0 || CFStringGetLength(model) > 128)
            return kAudioHardwareIllegalOperationError;
        CFMutableStringRef trimmed = CFStringCreateMutableCopy(NULL, 0, model);
        CFStringTrimWhitespace(trimmed);
        if (!CFStringGetLength(trimmed)) { CFRelease(trimmed); return kAudioHardwareIllegalOperationError; }
        if (!SonoFerryClientAuthorized(client)) { CFRelease(trimmed); return kAudioDevicePermissionsError; }
        pthread_mutex_lock(&gPlugIn_StateMutex);
        if (gLeaseOwner != client || !SonoFerryLeaseValid()) {
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            CFRelease(trimmed);
            return kAudioDevicePermissionsError;
        }
        Boolean changed = !CFEqual(gModel, trimmed);
        Boolean iconChanged = !CFEqual(SonoFerryIconName(gModel), SonoFerryIconName(trimmed));
        Boolean terminalChanged = SonoFerryTerminalType(gModel) != SonoFerryTerminalType(trimmed);
        CFRelease(gModel);
        gModel = trimmed;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        if (changed) {
            AudioObjectPropertyAddress properties[] = {
                {kSonoFerryModel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
                {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
                {kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
            };
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, iconChanged ? 3 : 2, properties);
            if (terminalChanged) {
                AudioObjectPropertyAddress terminal = {kAudioStreamPropertyTerminalType,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Stream_Output, 1, &terminal);
            }
        }
        return noErr;
    }
    if (object == kObjectID_Device && property->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return SonoFerrySetRate(client, *(const Float64 *)data);
    }
    if (object == kObjectID_Stream_Output && (property->mSelector == kAudioStreamPropertyVirtualFormat ||
        property->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *format = data;
        return SonoFerrySupportedRate(format->mSampleRate) && format->mFormatID == kAudioFormatLinearPCM &&
            format->mFormatFlags == (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) &&
            format->mBytesPerPacket == 8 && format->mFramesPerPacket == 1 && format->mBytesPerFrame == 8 &&
            format->mChannelsPerFrame == 2 && format->mBitsPerChannel == 32
            ? SonoFerrySetRate(client, format->mSampleRate) : kAudioDeviceUnsupportedFormatError;
    }
    if (object == kObjectID_Volume_Output_Master && (property->mSelector == kAudioLevelControlPropertyScalarValue ||
        property->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        if (size != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32 *)data;
        if (!isfinite(value) || (property->mSelector == kAudioLevelControlPropertyScalarValue
            ? value < 0 || value > 1 : value < kVolume_MinDB || value > kVolume_MaxDB))
            return kAudioHardwareIllegalOperationError;
    }
    if (object == kObjectID_Mute_Output_Master && property->mSelector == kAudioBooleanControlPropertyValue &&
        (size != sizeof(UInt32) || *(const UInt32 *)data > 1)) return kAudioHardwareIllegalOperationError;
    if ((object == kObjectID_Volume_Output_Master &&
         (property->mSelector == kAudioLevelControlPropertyScalarValue || property->mSelector == kAudioLevelControlPropertyDecibelValue)) ||
        (object == kObjectID_Mute_Output_Master && property->mSelector == kAudioBooleanControlPropertyValue)) {
        UInt32 count = 0;
        AudioObjectPropertyAddress changed[2];
        OSStatus status = noErr;
        if (qualifierSize) {
            if (qualifierSize != sizeof(UInt32) || !qualifier || *(const UInt32 *)qualifier != kSonoFerryLease)
                return kAudioHardwareIllegalOperationError;
            if (!SonoFerryClientAuthorized(client)) return kAudioDevicePermissionsError;
            pthread_mutex_lock(&gPlugIn_StateMutex);
            if (gShuttingDown || gLeaseOwner != client || !SonoFerryLeaseValid()) status = kAudioDevicePermissionsError;
            else if (object == kObjectID_Mute_Output_Master) {
                if (gMute_Output_Master_Value != (*(const UInt32 *)data != 0)) {
                    gMute_Output_Master_Value = *(const UInt32 *)data != 0;
                    count = 1;
                    changed[0] = (AudioObjectPropertyAddress){kAudioBooleanControlPropertyValue,
                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                }
            } else {
                Float32 volume = *(const Float32 *)data;
                if (property->mSelector == kAudioLevelControlPropertyDecibelValue)
                    volume = sqrtf((volume - kVolume_MinDB) / (kVolume_MaxDB - kVolume_MinDB));
                if (gVolume_Output_Master_Value != volume) {
                    gVolume_Output_Master_Value = volume;
                    count = 2;
                    changed[0] = (AudioObjectPropertyAddress){kAudioLevelControlPropertyScalarValue,
                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                    changed[1] = (AudioObjectPropertyAddress){kAudioLevelControlPropertyDecibelValue,
                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                }
            }
            pthread_mutex_unlock(&gPlugIn_StateMutex);
        } else status = NullAudio_SetControlPropertyData(driver, object, client, property,
            qualifierSize, qualifier, size, data, &count, changed);
        if (count) {
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, object, count, changed);
            AudioObjectPropertyAddress deviceProperty = {object == kObjectID_Volume_Output_Master
                ? kAudioDevicePropertyVolumeScalar : kAudioDevicePropertyMute,
                kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &deviceProperty);
        }
        return status;
    }
    return NullAudio_SetPropertyData(driver, object, client, property, qualifierSize, qualifier, size, data);
}

static OSStatus SonoFerryStartIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client) {
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    OSStatus status = noErr;
    if (!SonoFerryAlive()) status = kAudioHardwareNotRunningError;
    else if (gPendingRateAction || gDevice_IOIsRunning == UINT64_MAX) status = kAudioHardwareIllegalOperationError;
    else if (gDevice_IOIsRunning++ == 0) {
        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorSampleTime = 0;
        gDevice_AnchorHostTime = mach_absolute_time();
        atomic_store(&gClockAnchor, gDevice_AnchorHostTime);
        atomic_fetch_add(&gClockSeed, 1);
    }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return status;
}

static OSStatus SonoFerryZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                                Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (!sampleTime || !hostTime || !seed) return kAudioHardwareIllegalOperationError;
    UInt32 period = atomic_load(&gClockPeriod);
    Float64 ticks = atomic_load(&gClockTicksPerFrame) * period;
    UInt64 anchor = atomic_load(&gClockAnchor);
    UInt64 cycles = (mach_absolute_time() - anchor) / ticks;
    *sampleTime = cycles * period;
    *hostTime = anchor + (UInt64)(cycles * ticks);
    *seed = atomic_load(&gClockSeed);
    return noErr;
}

static OSStatus SonoFerryWillDoIO(AudioServerPlugInDriverRef driver, AudioObjectID device, UInt32 client,
                            UInt32 operation, Boolean *willDo, Boolean *inPlace) {
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (willDo) *willDo = operation == kAudioServerPlugInIOOperationWriteMix;
    if (inPlace) *inPlace = true;
    return noErr;
}

static OSStatus SonoFerryDoIO(AudioServerPlugInDriverRef driver, AudioObjectID device, AudioObjectID stream,
                        UInt32 client, UInt32 operation, UInt32 frames,
                        const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer) {
    if (driver != gAudioServerPlugInDriverRef || device != kObjectID_Device || stream != kObjectID_Stream_Output)
        return kAudioHardwareBadObjectError;
    return SonoFerryAlive() ? noErr : kAudioHardwareNotRunningError;
}

void *SonoFerryVirtualOutput_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gAudioServerPlugInDriverInterface.Release = SonoFerryRelease;
        gAudioServerPlugInDriverInterface.Initialize = SonoFerryInitialize;
        gAudioServerPlugInDriverInterface.PerformDeviceConfigurationChange = SonoFerryPerformConfiguration;
        gAudioServerPlugInDriverInterface.AbortDeviceConfigurationChange = SonoFerryAbortConfiguration;
        gAudioServerPlugInDriverInterface.HasProperty = SonoFerryHasProperty;
        gAudioServerPlugInDriverInterface.IsPropertySettable = SonoFerryIsSettable;
        gAudioServerPlugInDriverInterface.GetPropertyDataSize = SonoFerryGetSize;
        gAudioServerPlugInDriverInterface.GetPropertyData = SonoFerryGetData;
        gAudioServerPlugInDriverInterface.SetPropertyData = SonoFerrySetData;
        gAudioServerPlugInDriverInterface.StartIO = SonoFerryStartIO;
        gAudioServerPlugInDriverInterface.GetZeroTimeStamp = SonoFerryZeroTimeStamp;
        gAudioServerPlugInDriverInterface.WillDoIOOperation = SonoFerryWillDoIO;
        gAudioServerPlugInDriverInterface.DoIOOperation = SonoFerryDoIO;
    });
    return NullAudio_Create(allocator, type);
}
