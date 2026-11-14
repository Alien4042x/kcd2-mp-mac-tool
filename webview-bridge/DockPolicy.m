#import <AppKit/AppKit.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <signal.h>
#include "DockPolicyGate.h"

static CFRunLoopTimerRef policyTimer;
static int traceFD = -1;
static const char policyABI[] = "KCDMP_DOCK_POLICY_ABI_1";
static pid_t ownerPID;

static void note(const char *message) {
    if (traceFD >= 0) dprintf(traceFD, "%d %s\n", getpid(), message);
}

// Preserve the preload through Wine's native bootstrap re-exec, then remove
// only this library from the Unix environment once Cocoa is ready.
static void removeOwnPreload(void) {
    const char *value = getenv("DYLD_INSERT_LIBRARIES");
    Dl_info own;
    if (!value || !dladdr((const void *)&removeOwnPreload, &own) || !own.dli_fname) return;
    NSString *path = [[NSString stringWithUTF8String:own.dli_fname] stringByResolvingSymlinksInPath];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *item in [[NSString stringWithUTF8String:value] componentsSeparatedByString:@":"]) {
        if (![[item stringByResolvingSymlinksInPath] isEqualToString:path]) [kept addObject:item];
    }
    if (kept.count) setenv("DYLD_INSERT_LIBRARIES", [[kept componentsJoinedByString:@":"] UTF8String], 1);
    else unsetenv("DYLD_INSERT_LIBRARIES");
}

static void isolateFutureChildren(void) {
    removeOwnPreload();
    unsetenv("KCDMP_DOCK_EXPECTED_EXE");
    unsetenv("KCDMP_DOCK_LOG");
    unsetenv("KCDMP_DOCK_OWNER_PID");
}

static void applyDockPolicy(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    (void)context;
    @autoreleasepool {
        static BOOL observedApp = NO;
        if (!NSApp) return;
        if (!observedApp) {
            observedApp = YES;
            isolateFutureChildren();
            note("Cocoa ready, own preload removed from future child environments");
        }
        if (kill(ownerPID, 0) != 0) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            note("Mac launcher is gone, restored the backend Dock entry");
            CFRunLoopTimerInvalidate(timer);
            return;
        }
        if (NSApp.activationPolicy == NSApplicationActivationPolicyRegular) {
            BOOL changed = [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            note(changed && NSApp.activationPolicy == NSApplicationActivationPolicyAccessory
                 ? "launcher activation policy is accessory" : "launcher activation policy change refused");
        }
    }
}

__attribute__((constructor)) static void installDockPolicy(void) {
    @autoreleasepool {
        int allowed = kcdmp_dock_allowed(*_NSGetArgc(), (const char *const *)*_NSGetArgv(),
                                        getenv("KCDMP_WEBKIT_BRIDGE_ENABLED"), getenv("KCDMP_DOCK_EXPECTED_EXE"),
                                        getenv("KCDMP_WEBKIT_BRIDGE_TOKEN"));
        ownerPID = (pid_t)kcdmp_dock_owner(getenv("KCDMP_DOCK_OWNER_PID"));
        if (!ownerPID) allowed = 0;
        const char *log = getenv("KCDMP_DOCK_LOG");
        if (log && getenv("KCDMP_DOCK_EXPECTED_EXE")) traceFD = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (!allowed) {
            isolateFutureChildren();
            note("launcher Dock policy identity gate refused this process");
            return;
        }
        note(policyABI);
#ifdef __x86_64__
        note("launcher bootstrap x86_64, preserving own preload until Cocoa is ready");
#else
        note("launcher bootstrap arm64, preserving own preload until Cocoa is ready");
#endif
        // Do not create NSApplication here. Wine must create its own subclass.
        // Use common-mode timers for Wine's nested Cocoa loop rather than
        // depending on main dispatch queue delivery during Wine startup.
        CFRunLoopTimerContext context = {0};
        policyTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0.1, 0, 0, applyDockPolicy, &context);
        if (!policyTimer) { note("Cocoa run-loop timer creation failed"); return; }
        CFRunLoopTimerSetTolerance(policyTimer, 0.02);
        CFRunLoopAddTimer(CFRunLoopGetMain(), policyTimer, kCFRunLoopCommonModes);
        CFRunLoopWakeUp(CFRunLoopGetMain());
    }
}
