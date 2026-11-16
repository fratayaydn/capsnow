// capsnowd: turns off the Caps Lock delay on every keyboard, then quits.
// macOS normally ignores very short Caps Lock presses. The HID event system has a property for that delay
// (CapsLockDelayOverride, in milliseconds) that resets at every restart. launchd starts this helper at login and
// whenever a keyboard appears (an IOKit matching launch event, which also fires when a keyboard is reconnected or
// recreated after sleep), so nothing has to stay running.
//
//   capsnowd          apply the setting (what launchd runs)
//   capsnowd --off    remove the override: macOS uses its own delay again
//   capsnowd --status print the current delay
//   capsnowd --log    print the running agent's diagnostic log (diagnostic builds only)
#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <xpc/xpc.h>
#import "DiagnosticLog.h"

// Overrides the keyboard's own delay (75 ms on Apple keyboards). -1 means no override, the value the keyboard
// filter starts with (IOHIDKeyboardFilter in Apple's IOHIDFamily); only values above 0 replace the delay, and 0
// turns it off.
#define CAPS_LOCK_DELAY CFSTR("CapsLockDelayOverride")
#define NO_OVERRIDE     -1

static void setDelay(int ms) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &ms);
    DIAG(@"set Caps Lock delay override=%d ms", ms);
    if (!IOHIDEventSystemClientSetProperty(client, CAPS_LOCK_DELAY, n)) {
        DIAG(@"could not set the Caps Lock delay");
        if (ms == NO_OVERRIDE) fprintf(stderr, "capsnowd: could not set the Caps Lock delay\n");
    } else {
        DIAG(@"Caps Lock delay override accepted=%d ms", ms);
    }
    CFRelease(n);
    CFRelease(client);
}

static void applyNoDelay(void) { setDelay(0); }

static void removeOverride(void) { setDelay(NO_OVERRIDE); }

static void printStatus(void) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFTypeRef value = IOHIDEventSystemClientCopyProperty(client, CAPS_LOCK_DELAY);
    int ms = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &ms);
    DIAG(@"Caps Lock delay status=%d ms (-1 means macOS default)", ms);
    if (ms >= 0) printf("Caps Lock delay: %d ms\n", ms);
    else printf("Caps Lock delay: macOS default\n");
    if (value) CFRelease(value);
    CFRelease(client);
}

#ifdef CAPSNOW_DIAGNOSTIC_LOG
static CFAbsoluteTime gDiagnosticLastEvent;

static CFTimeInterval diagnosticExitDelay(CFAbsoluteTime lastEvent, CFAbsoluteTime now) {
    return MAX(0, lastEvent + 300 - now);
}

static void diagnosticExitWhenIdle(void) {
    CFTimeInterval delay = diagnosticExitDelay(gDiagnosticLastEvent, CFAbsoluteTimeGetCurrent());
    if (delay == 0) {
        DIAG(@"agent exit");
        exit(0);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ diagnosticExitWhenIdle(); });
}
#endif

int main(int argc, char **argv) {
    @autoreleasepool {
#ifdef CAPSNOW_DIAGNOSTIC_LOG
        if (argc > 1 && !strcmp(argv[1], "--log")) return diagnosticPrint();
#endif
        if (argc > 1 && !strcmp(argv[1], "--status")) { printStatus(); return 0; }
        if (argc > 1 && !strcmp(argv[1], "--off")) { removeOverride(); return 0; }

#ifdef CAPSNOW_DIAGNOSTIC_LOG
        DIAG(@"agent start");
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, diagnosticRequested,
                                        LOG_REQUEST, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        gDiagnosticLastEvent = CFAbsoluteTimeGetCurrent();
        diagnosticExitWhenIdle();
#endif
        // launchd delivers the keyboard event that started us; it must be received, or launchd starts us again
        // for the same event.
        xpc_set_event_stream_handler("com.apple.iokit.matching", dispatch_get_main_queue(), ^(xpc_object_t event) {
            DIAG(@"keyboard matching event");
#ifdef CAPSNOW_DIAGNOSTIC_LOG
            gDiagnosticLastEvent = CFAbsoluteTimeGetCurrent();
#endif
            applyNoDelay();
        });
        applyNoDelay();
        // A keyboard can finish starting just after it matched: apply once more, then quit.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            DIAG(@"keyboard startup retry");
            applyNoDelay();
#ifndef CAPSNOW_DIAGNOSTIC_LOG
            DIAG(@"agent exit");
            exit(0);
#endif
        });
        dispatch_main();
    }
    return 0;
}
