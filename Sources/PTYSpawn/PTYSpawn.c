#include "PTYSpawn.h"

#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <util.h>

pid_t pty_spawn(const char *path, char *const argv[], char *const envp[],
                const char *directory, struct winsize *size, int *master)
{
    // Built before the fork, so the child only has to apply them.
    struct sigaction fallback;
    fallback.sa_handler = SIG_DFL;
    sigemptyset(&fallback.sa_mask);
    fallback.sa_flags = 0;
    sigset_t empty;
    sigemptyset(&empty);

    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, size);
    if (pid < 0) return -1;

    if (pid == 0) {
        // Ignored signals and the calling thread's mask both survive exec. The app
        // ignores or blocks some signals for its own reasons, and a shell must not
        // inherit that. Handlers are reset before the mask is cleared, so none of the
        // app's handlers can run here between fork and exec. Some numbers are reserved,
        // and sigaction turns those down with EINVAL, which is fine.
        for (int number = 1; number < NSIG; number++) {
            if (number != SIGKILL && number != SIGSTOP) sigaction(number, &fallback, NULL);
        }
        if (sigprocmask(SIG_SETMASK, &empty, NULL) != 0) _exit(127);
        if (directory != NULL) (void)chdir(directory);
        execve(path, argv, envp);
        _exit(127);
    }

    // The master is the app's alone. Without this, every shell started later would get a
    // copy of it through exec, and a tab's terminal would stay open after the tab closed.
    int flags = fcntl(fd, F_GETFD);
    if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);

    *master = fd;
    return pid;
}
