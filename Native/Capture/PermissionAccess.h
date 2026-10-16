// TCC SPI is isolated here. No tap, aggregate device, microphone or audio I/O is created.
#include <dlfcn.h>
#include <stdatomic.h>
static const char *SonoFerryPermissionName(int64_t raw) {
    switch (raw) { case 0: return "granted"; case 1: return "denied"; case 2: return "notDetermined"; default: return "unavailable"; }
}
static int SonoFerryPermissionCommand(BOOL request) {
    void *api = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW | RTLD_LOCAL);
    int64_t (*preflight)(CFStringRef, CFDictionaryRef) = api ? dlsym(api, "TCCAccessPreflight") : NULL;
    void (*requestAccess)(CFStringRef, CFDictionaryRef, void (^)(BOOL)) = api ? dlsym(api, "TCCAccessRequest") : NULL;
    if (!preflight || (request && !requestAccess)) { puts("{\"audioCapture\":\"unavailable\"}"); return 0; }
    if (request) {
        __block atomic_bool finished = false;
        requestAccess(CFSTR("kTCCServiceAudioCapture"), NULL, ^(BOOL granted) { (void)granted; atomic_store(&finished, true); });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:55];
        while (!atomic_load(&finished) && deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (!atomic_load(&finished)) { puts("{\"audioCapture\":\"unavailable\",\"permissionError\":\"授权等待超时，请在系统设置中检查\"}"); return 0; }
    }
    int64_t raw = preflight(CFSTR("kTCCServiceAudioCapture"), NULL);
    printf("{\"audioCapture\":\"%s\",\"audioCaptureRaw\":\"%lld\"}\n", SonoFerryPermissionName(raw), (long long)raw);
    return 0;
}
