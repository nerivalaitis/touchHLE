#include <SDL.h>
#include <SDL_system.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <objc/message.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "TouchHLEHost-Bridging-Header.h"

#import <Foundation/Foundation.h>

// Not declared in the public SDK, but a stable syscall wrapper in libSystem.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define TOUCHHLE_CS_OPS_STATUS 0
#define TOUCHHLE_CS_DEBUGGED 0x10000000

extern int32_t touchhle_ios_run_game(
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);

static FILE *diagnostic_log;

static void redirect_diagnostics(void) {
    const char *home = getenv("HOME");
    if (home == NULL) {
        return;
    }

    char log_path[PATH_MAX];
    int length = snprintf(log_path, sizeof(log_path), "%s/Documents/touchhle-host.log", home);
    if (length < 0 || (size_t)length >= sizeof(log_path)) {
        return;
    }

    // If a game hangs, the only way out is to force-quit, and the next launch
    // would truncate the log that recorded the hang. Keep one generation back
    // so the interesting session survives the relaunch needed to retrieve it.
    char previous_path[PATH_MAX];
    length = snprintf(
        previous_path,
        sizeof(previous_path),
        "%s/Documents/touchhle-host-previous.log",
        home
    );
    if (length > 0 && (size_t)length < sizeof(previous_path)) {
        rename(log_path, previous_path);
    }

    diagnostic_log = fopen(log_path, "w");
    if (diagnostic_log == NULL) {
        return;
    }

    setvbuf(diagnostic_log, NULL, _IONBF, 0);
    dup2(fileno(diagnostic_log), STDOUT_FILENO);
    dup2(fileno(diagnostic_log), STDERR_FILENO);

    time_t now = time(NULL);
    char stamp[64];
    struct tm parts;
    if (localtime_r(&now, &parts) != NULL
        && strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &parts) > 0) {
        fprintf(stderr, "touchHLE iOS port diagnostics started at %s\n", stamp);
    } else {
        fprintf(stderr, "touchHLE iOS port diagnostics started\n");
    }
}

// Dynarmic needs writable-executable memory. Two things can grant it:
//
//   * An attached debugger (TrollStore's "Enable JIT", StikDebug, AltJIT),
//     which sets CS_DEBUGGED on the process. This has to be redone every time
//     the app starts as a new process.
//   * The `dynamic-codesigning` entitlement, which makes it permanent. iOS 15+
//     only honours this on A11 and older chips.
//
// Do NOT probe this by mmap'ing PROT_WRITE | PROT_EXEC. Per mmap(2), iOS
// returns a writable-but-NOT-executable mapping instead of failing when
// MAP_JIT is absent, so that probe succeeds even with no JIT and is useless.
bool touchhle_ios_jit_is_from_debugger(void) {
    unsigned int flags = 0;
    if (csops(getpid(), TOUCHHLE_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & TOUCHHLE_CS_DEBUGGED) != 0;
}

// SecTask lives in Security.framework but is not declared in the iOS SDK.
// Resolve it at runtime so a missing symbol degrades to "no entitlement"
// instead of preventing the app from launching at all.
static bool touchhle_has_dynamic_codesigning(void) {
    typedef CFTypeRef (*create_from_self_fn)(CFAllocatorRef);
    typedef CFTypeRef (*copy_entitlement_fn)(CFTypeRef, CFStringRef, CFErrorRef *);

    static create_from_self_fn create_task;
    static copy_entitlement_fn copy_entitlement;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *security = dlopen(
            "/System/Library/Frameworks/Security.framework/Security",
            RTLD_LAZY
        );
        if (security == NULL) {
            return;
        }
        create_task = (create_from_self_fn)dlsym(security, "SecTaskCreateFromSelf");
        copy_entitlement =
            (copy_entitlement_fn)dlsym(security, "SecTaskCopyValueForEntitlement");
    });

    if (create_task == NULL || copy_entitlement == NULL) {
        return false;
    }

    CFTypeRef task = create_task(kCFAllocatorDefault);
    if (task == NULL) {
        return false;
    }
    CFTypeRef value = copy_entitlement(task, CFSTR("dynamic-codesigning"), NULL);
    bool granted = value != NULL
        && CFGetTypeID(value) == CFBooleanGetTypeID()
        && CFBooleanGetValue((CFBooleanRef)value);
    if (value != NULL) {
        CFRelease(value);
    }
    CFRelease(task);
    return granted;
}

// mmap RWX: per mmap(2) iOS silently downgrades this to writable-only rather
// than failing, so a success here proves nothing. Recorded for diagnosis only.
static bool touchhle_probe_mmap_rwx(void) {
    size_t page_size = (size_t)getpagesize();
    void *page = mmap(
        NULL,
        page_size,
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );
    if (page == MAP_FAILED) {
        return false;
    }
    munmap(page, page_size);
    return true;
}

// Flipping an existing anonymous RW page to R+X. Unlike the mmap case the
// kernel actually enforces this, so it is the closest safe stand-in for what
// Dynarmic needs. Not executed - only the permission change is tested.
static bool touchhle_probe_mprotect_exec(void) {
    size_t page_size = (size_t)getpagesize();
    void *page = mmap(
        NULL,
        page_size,
        PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );
    if (page == MAP_FAILED) {
        return false;
    }
    bool ok = mprotect(page, page_size, PROT_READ | PROT_EXEC) == 0;
    munmap(page, page_size);
    return ok;
}

void touchhle_ios_jit_diagnostics(TouchHLEJITDiagnostics *out) {
    if (out == NULL) {
        return;
    }
    unsigned int flags = 0;
    int result = csops(getpid(), TOUCHHLE_CS_OPS_STATUS, &flags, sizeof(flags));

    out->csops_result = result;
    out->csops_errno = (result == 0) ? 0 : errno;
    out->cs_flags = flags;
    out->cs_debugged = (flags & TOUCHHLE_CS_DEBUGGED) != 0;
    out->has_dynamic_codesigning = touchhle_has_dynamic_codesigning();
    out->mmap_rwx_ok = touchhle_probe_mmap_rwx();
    out->mprotect_exec_ok = touchhle_probe_mprotect_exec();
}

// Only CS_DEBUGGED and the entitlement get a vote. Neither memory probe can
// detect JIT on iOS, and both were observed reporting success with JIT off:
//
//   * mmap PROT_WRITE|PROT_EXEC - per mmap(2) iOS quietly returns a
//     writable-but-not-executable mapping instead of failing.
//   * mprotect to PROT_READ|PROT_EXEC - drops write, so it is the W^X-legal
//     transition the kernel always allows. Code-signing enforcement happens
//     when the page is executed, not when it is re-protected.
//
// The probes stay in the diagnostics struct for reporting, but must never
// influence the verdict: a false "JIT is on" sends the emulator into a
// guaranteed freeze with no explanation.
bool touchhle_ios_jit_available(void) {
    TouchHLEJITDiagnostics diagnostics;
    touchhle_ios_jit_diagnostics(&diagnostics);
    return diagnostics.cs_debugged || diagnostics.has_dynamic_codesigning;
}

void touchhle_ios_log_jit_status(const char *context) {
    TouchHLEJITDiagnostics d;
    touchhle_ios_jit_diagnostics(&d);
    fprintf(
        stderr,
        "touchHLE JIT [%s]: available=%s cs_flags=0x%08x csops=%d/%d "
        "debugged=%d entitlement=%d mmap_rwx=%d mprotect_exec=%d\n",
        context ? context : "?",
        touchhle_ios_jit_available() ? "yes" : "no",
        d.cs_flags,
        d.csops_result,
        d.csops_errno,
        d.cs_debugged,
        d.has_dynamic_codesigning,
        d.mmap_rwx_ok,
        d.mprotect_exec_ok
    );
}

static void start_native_host(void) {
    Class host_class = NSClassFromString(@"TouchHLENativeHost");
    SEL selector = NSSelectorFromString(@"start");
    if (host_class == Nil || ![host_class respondsToSelector:selector]) {
        fprintf(stderr, "Could not start the native iOS port UI\n");
        return;
    }

    ((void (*)(id, SEL))objc_msgSend)(host_class, selector);
}

int32_t touchhle_ios_launch_game(
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
) {
    const char *orientation_hint = "Portrait";
    if (orientation == 1) {
        orientation_hint = "LandscapeLeft";
    } else if (orientation == 2) {
        orientation_hint = "LandscapeRight";
    }
    SDL_SetHint(SDL_HINT_ORIENTATIONS, orientation_hint);

    // Breadcrumbs: the emulator runs on the main thread, so if it hangs the UI
    // freezes with it and the log is the only way to see how far it got.
    touchhle_ios_log_jit_status("game-launch");
    fprintf(
        stderr,
        "touchHLE: entering emulator: path=%s scale_hack=%d orientation=%s "
        "network=%d analog_tilt=%d\n",
        path,
        scale_hack,
        orientation_hint,
        network_access,
        analog_stick_tilt_controls
    );

    SDL_iPhoneSetEventPump(SDL_TRUE);
    int32_t result = touchhle_ios_run_game(
        path,
        scale_hack,
        orientation,
        network_access,
        analog_stick_tilt_controls
    );
    SDL_iPhoneSetEventPump(SDL_FALSE);
    SDL_ResetHint(SDL_HINT_ORIENTATIONS);

    fprintf(stderr, "touchHLE: emulator returned %d\n", result);
    return result;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    redirect_diagnostics();
    touchhle_ios_log_jit_status("launch");

    char *base_path = SDL_GetBasePath();
    if (base_path != NULL) {
        chdir(base_path);
        SDL_free(base_path);
    }

    start_native_host();
    return 0;
}
