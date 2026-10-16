#define main CaptureMain
#include "SystemAudioTap.m"
#undef main
#include <dispatch/dispatch.h>
#include "PermissionAccess.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--permission-status") == 0) return SonoFerryPermissionCommand(NO);
        if (argc == 2 && strcmp(argv[1], "--request-permission") == 0) return SonoFerryPermissionCommand(YES);
        if (argc == 2 && strcmp(argv[1], "--permission-self-test") == 0) {
            assert(strcmp(SonoFerryPermissionName(0), "granted") == 0);
            assert(strcmp(SonoFerryPermissionName(1), "denied") == 0);
            assert(strcmp(SonoFerryPermissionName(2), "notDetermined") == 0);
            assert(strcmp(SonoFerryPermissionName(3), "unavailable") == 0);
            assert(strcmp(SonoFerryPermissionName(-1), "unavailable") == 0);
            puts("permission status mapping passed; no TCC calls"); return 0;
        }
        setbuf(stdout, NULL);
        sigset_t processSignals;
        pthread_sigmask(SIG_SETMASK, NULL, &processSignals);
        printf("PROCESS_SIGNALS blockedINT=%d blockedTERM=%d\n",
               sigismember(&processSignals, SIGINT), sigismember(&processSignals, SIGTERM));
        CFRunLoopRef mainLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceContext context = {0};
        CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &context);
        CFRunLoopAddSource(mainLoop, source, kCFRunLoopDefaultMode);
        __block int status = 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            printf("MAIN_RUNLOOP_READY\n");
        });
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            int result = CaptureMain(argc, argv);
            dispatch_async(dispatch_get_main_queue(), ^{
                status = result;
                CFRunLoopStop(mainLoop);
            });
        });
        printf("MAIN_RUNLOOP_BEGIN captureThread=worker\n");
        CFRunLoopRun();
        CFRunLoopRemoveSource(mainLoop, source, kCFRunLoopDefaultMode);
        CFRelease(source);
        printf("MAIN_RUNLOOP_END status=%d\n", status);
        return status;
    }
}
