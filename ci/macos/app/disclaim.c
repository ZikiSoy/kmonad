// kmonad-disclaim: run a program as its own "responsible process" for TCC.
//
// kmonad is started by kmonad-supervisor (a bash script run by launchd). By
// default macOS attributes privacy checks such as Input Monitoring to the
// launchd job's program (/bin/bash), so granting kmonad itself would not help.
// Disclaiming responsibility makes macOS check the kmonad binary instead.
//
// Usage: kmonad-disclaim /path/to/program [args...]
// Forwards SIGTERM/SIGINT/SIGHUP to the child and exits with its status.

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
// Private but stable libsystem API (used by Terminal, iTerm2, Chromium, LLDB).
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim)
    __attribute__((weak_import));

static pid_t child = 0;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: kmonad-disclaim program [args...]\n");
        return 2;
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    if (responsibility_spawnattrs_setdisclaim) {
        int r = responsibility_spawnattrs_setdisclaim(&attr, 1);
        if (r != 0) fprintf(stderr, "kmonad-disclaim: setdisclaim failed: %s\n", strerror(r));
    } else {
        fprintf(stderr, "kmonad-disclaim: responsibility API unavailable\n");
    }

    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);

    int r = posix_spawn(&child, argv[1], NULL, &attr, argv + 1, environ);
    posix_spawnattr_destroy(&attr);
    if (r != 0) {
        fprintf(stderr, "kmonad-disclaim: %s: %s\n", argv[1], strerror(r));
        return 127;
    }

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
