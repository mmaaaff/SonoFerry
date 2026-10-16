#include <dispatch/dispatch.h>
#include <signal.h>
#include <unistd.h>

static dispatch_source_t ldacParentLifetime;

static int LDACWatchParent(unsigned graceSeconds) {
    pid_t parent = getppid();
    if (parent <= 1) return 0;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    ldacParentLifetime = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent, DISPATCH_PROC_EXIT, queue);
    if (!ldacParentLifetime) return 0;
    dispatch_source_set_event_handler(ldacParentLifetime, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)graceSeconds * NSEC_PER_SEC), queue, ^{
            kill(getpid(), SIGKILL);
        });
    });
    dispatch_resume(ldacParentLifetime);
    return getppid() == parent;
}
