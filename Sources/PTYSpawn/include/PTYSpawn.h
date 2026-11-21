#ifndef PTYSPAWN_H
#define PTYSPAWN_H

#include <sys/ioctl.h>
#include <sys/types.h>

// Starts `path` on a new pseudo terminal, with the terminal as its controlling tty.
//
// Everything the child needs is built by the caller before this is called: between fork
// and exec the child may only make async-signal-safe calls, so it cannot allocate, and
// Swift code cannot promise that. This is the whole of what runs in the child.
//
// Returns the child's pid and writes the master side to `master`, or returns -1 with
// errno set. `directory` may be NULL to stay where the parent is.
pid_t pty_spawn(const char *path, char *const argv[], char *const envp[],
                const char *directory, struct winsize *size, int *master);

#endif
