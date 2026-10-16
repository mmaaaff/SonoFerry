#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t interrupted;

static void Interrupt(int value) {
    interrupted = value;
}

static double MonotonicTime(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    pid_t parent = getppid();
    if (parent <= 1) return 1;
    struct sigaction action = {0};
    action.sa_handler = Interrupt;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL)) return 1;
    sigset_t mask;
    sigemptyset(&mask);
    if (sigprocmask(SIG_SETMASK, &mask, NULL)) return 1;
    argv[0] = "/usr/bin/log";
    pid_t child = 0;
    int error = posix_spawn(&child, argv[0], NULL, NULL, argv, environ);
    if (error) {
        fprintf(stderr, "LOG_OBSERVER_SPAWN_FAILED error=%d\n", error);
        return 1;
    }
    int status = 0;
    while (!interrupted && getppid() == parent) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        if (result < 0 && errno != EINTR) return 1;
        struct pollfd input = {STDIN_FILENO, POLLIN, 0};
        int ready = poll(&input, 1, 50);
        if (ready < 0 && errno != EINTR) break;
        if (ready > 0) {
            if (input.revents & (POLLHUP | POLLERR | POLLNVAL)) break;
            if (input.revents & POLLIN) {
                char buffer[256];
                ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
                if (count == 0 || (count < 0 && errno != EINTR)) break;
            }
        }
    }
    kill(child, SIGTERM);
    double deadline = MonotonicTime() + 0.5;
    while (MonotonicTime() < deadline) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) return 0;
        if (result < 0 && errno != EINTR) return 1;
        poll(NULL, 0, 10);
    }
    kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 1;
    }
    return 1;
}
