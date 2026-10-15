// capsnowd: turns off the Caps Lock delay on every keyboard, then quits.
// macOS normally ignores very short Caps Lock presses. The HID event system has a property for that delay
// (CapsLockDelayOverride, in milliseconds) that resets at every restart. launchd starts this helper at login and
// whenever a keyboard appears (an IOKit matching launch event, which also fires when a keyboard is reconnected or
// recreated after sleep), so nothing has to stay running.
//
//   capsnowd          apply the setting (what launchd runs)
//   capsnowd --off    remove the override: macOS uses its own delay again
//   capsnowd --status print the current delay
#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <xpc/xpc.h>

// Overrides the keyboard's own delay (75 ms on Apple keyboards). -1 means no override, the value the keyboard
// filter starts with (IOHIDKeyboardFilter in Apple's IOHIDFamily); only values above 0 replace the delay, and 0
// turns it off.
#define CAPS_LOCK_DELAY CFSTR("CapsLockDelayOverride")
#define NO_OVERRIDE     -1

static void setDelay(int ms) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &ms);
    if (!IOHIDEventSystemClientSetProperty(client, CAPS_LOCK_DELAY, n))
        fprintf(stderr, "capsnowd: could not set the Caps Lock delay\n");
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
    if (ms >= 0) printf("Caps Lock delay: %d ms\n", ms);
    else printf("Caps Lock delay: macOS default\n");
    if (value) CFRelease(value);
    CFRelease(client);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--status")) { printStatus(); return 0; }
        if (argc > 1 && !strcmp(argv[1], "--off")) { removeOverride(); return 0; }

        // launchd delivers the keyboard event that started us; it must be received, or launchd starts us again
        // for the same event.
        xpc_set_event_stream_handler("com.apple.iokit.matching", dispatch_get_main_queue(), ^(xpc_object_t event) {
            applyNoDelay();
        });
        applyNoDelay();
        // A keyboard can finish starting just after it matched: apply once more, then quit.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            applyNoDelay();
            exit(0);
        });
        dispatch_main();
    }
    return 0;
}
