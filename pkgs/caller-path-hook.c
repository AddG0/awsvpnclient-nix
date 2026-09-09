/*
 * LD_PRELOAD shim for the AWS VPN Client daemon (see service.nix).
 *
 * Every IPC request is guarded by the daemon's process validator: it readlink()s
 * /proc/<caller>/exe and rejects the call unless the executable sits directly in
 * /opt/awsvpnclient. The GUI and CLI run in their own buildFHSEnv sandbox, where
 * /opt/awsvpnclient is a bind mount of a Nix store path, so from the daemon's
 * mount namespace their exe resolves to
 *
 *   /nix/store/...-awsvpnclient-deb-<ver>/opt/awsvpnclient/AWS VPN Client
 *
 * and the daemon answers "Binary path of caller PID ... not allowed".
 *
 * The hooks below rewrite a /proc/<pid>/exe target that ends in one of the two
 * accepted executables back to its bare /opt/awsvpnclient path. Every other
 * readlink is returned untouched, so the check still rejects anything else.
 *
 * This is the same workaround the 5.4.0 packaging needed (the D-Bus half of the
 * old acvc-hook.c is gone: 6.0.0 moved the IPC to a Unix socket).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

static const char *const allowed_exes[] = {
    "/opt/awsvpnclient/AWS VPN Client",
    "/opt/awsvpnclient/aws-vpn-client",
};

static int is_proc_exe(const char *pathname) {
    if (!pathname || strncmp(pathname, "/proc/", 6) != 0) return 0;
    size_t len = strlen(pathname);
    return len >= 4 && strcmp(pathname + len - 4, "/exe") == 0;
}

/* readlink() does not NUL-terminate; n is the byte count written to buf. A caller
   that passed too small a buffer gets n == bufsiz and a truncated target, which
   simply fails to match and is retried by the caller with a larger buffer. */
static ssize_t rewrite_caller_exe(const char *pathname, char *buf, ssize_t n, size_t bufsiz) {
    if (n <= 0 || !is_proc_exe(pathname)) return n;

    for (size_t i = 0; i < sizeof(allowed_exes) / sizeof(allowed_exes[0]); i++) {
        const char *exe = allowed_exes[i];
        size_t exe_len = strlen(exe);
        /* Only a store-prefixed copy of that exact path is rewritten. */
        if ((size_t)n <= exe_len || memcmp(buf + (size_t)n - exe_len, exe, exe_len) != 0) continue;
        if (exe_len > bufsiz) return n;
        memcpy(buf, exe, exe_len);
        return (ssize_t)exe_len;
    }
    return n;
}

typedef ssize_t (*orig_readlink_t)(const char *pathname, char *buf, size_t bufsiz);
ssize_t readlink(const char *pathname, char *buf, size_t bufsiz) {
    static orig_readlink_t orig = NULL;
    if (!orig) orig = dlsym(RTLD_NEXT, "readlink");
    return rewrite_caller_exe(pathname, buf, orig(pathname, buf, bufsiz), bufsiz);
}

typedef ssize_t (*orig_readlinkat_t)(int dirfd, const char *pathname, char *buf, size_t bufsiz);
ssize_t readlinkat(int dirfd, const char *pathname, char *buf, size_t bufsiz) {
    static orig_readlinkat_t orig = NULL;
    if (!orig) orig = dlsym(RTLD_NEXT, "readlinkat");
    return rewrite_caller_exe(pathname, buf, orig(dirfd, pathname, buf, bufsiz), bufsiz);
}
