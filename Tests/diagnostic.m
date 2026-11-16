// Check diagnostics with private notifications and a simulated HID client.
#include <assert.h>
#import <Foundation/Foundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <xpc/xpc.h>
#include <unistd.h>

static BOOL testWriteAccepted = YES;
static int testDelay, testWrites;
static CFTypeRef testStatus;

static IOHIDEventSystemClientRef testCreateClient(CFAllocatorRef allocator) {
    return (IOHIDEventSystemClientRef)CFRetain(CFSTR("test-client"));
}

static Boolean testSetProperty(IOHIDEventSystemClientRef client, CFStringRef key, CFTypeRef value) {
    assert(CFEqual(key, CFSTR("CapsLockDelayOverride")));
    assert(CFNumberGetValue(value, kCFNumberIntType, &testDelay));
    testWrites++;
    return testWriteAccepted;
}

static CFTypeRef testCopyProperty(IOHIDEventSystemClientRef client, CFStringRef key) {
    assert(CFEqual(key, CFSTR("CapsLockDelayOverride")));
    return testStatus ? CFRetain(testStatus) : NULL;
}

#define IOHIDEventSystemClientCreateSimpleClient testCreateClient
#define IOHIDEventSystemClientSetProperty testSetProperty
#define IOHIDEventSystemClientCopyProperty testCopyProperty
#define CFNotificationCenterGetDistributedCenter CFNotificationCenterGetLocalCenter
#define main capsnowAgentMain
#import "../Sources/Agent/capsnowd.m"
#undef main

#ifdef CAPSNOW_DIAGNOSTIC_LOG
static void resetLog(void) {
    for (NSUInteger i = 0; i < 500; i++) gDiagnosticEntries[i] = nil;
    gDiagnosticHead = gDiagnosticCount = 0;
}

static void testLifetime(void) {
    assert(diagnosticExitDelay(1000, 1000) == 300);
    assert(diagnosticExitDelay(1000, 1002) == 298);
    assert(diagnosticExitDelay(1000, 1299.5) == 0.5);
    assert(diagnosticExitDelay(1000, 1300) == 0);
    assert(diagnosticExitDelay(1000, 1301) == 0);
    // A matching event restarts the idle period; the startup retry does not.
    assert(diagnosticExitDelay(1299, 1300) == 299);
    assert(diagnosticExitDelay(1299, 1599) == 0);
}

static void testRing(void) {
    resetLog();
    for (int i = 0; i < 750; i++) DIAG(@"event %d", i);
    NSArray *entries = diagnosticRead();
    assert(entries.count == 500);
    assert([entries.firstObject[@"text"] isEqual:@"event 250"]);
    assert([entries.lastObject[@"text"] isEqual:@"event 749"]);
    for (NSUInteger i = 1; i < entries.count; i++)
        assert([entries[i - 1][@"timestamp"] doubleValue] <= [entries[i][@"timestamp"] doubleValue]);

    // The oldest entry expires on read, even without another event.
    gDiagnosticEntries[gDiagnosticHead] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 301), @"text": @"expired"};
    assert(diagnosticRead().count == 499);
    assert(gDiagnosticEntries[(gDiagnosticHead + 499) % 500] == nil);

    // Expired entries are also removed on add.
    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 301), @"text": @"expired"};
    gDiagnosticCount = 1;
    DIAG(@"fresh");
    entries = diagnosticRead();
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"fresh"]);
    assert(gDiagnosticEntries[0] == nil);

    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @700, @"text": @"boundary"};
    gDiagnosticCount = 1;
    diagnosticPrune(1000);
    assert(gDiagnosticCount == 1);
    diagnosticPrune(1000.001);
    assert(gDiagnosticCount == 0 && gDiagnosticEntries[0] == nil);
}

static void testReply(void) {
    resetLog();
    DIAG(@"agent start");
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    NSArray *entries = nil;
    CFNotificationCenterAddObserver(center, NULL, diagnosticRequested, LOG_REQUEST, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, &entries, diagnosticReceived, LOG_REPLY, CFSTR("test-token"),
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("different-token"), NULL, true);
    assert(entries == nil);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"agent start"]);
    resetLog();
    entries = nil;
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries != nil && entries.count == 0);
    CFNotificationCenterRemoveEveryObserver(center, NULL);
    CFNotificationCenterRemoveEveryObserver(center, &entries);
}

static void testPrint(void) {
    resetLog();
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    CFNotificationCenterAddObserver(center, NULL, diagnosticRequested, LOG_REQUEST, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    FILE *output = tmpfile();
    assert(output);
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    assert(saved >= 0 && dup2(fileno(output), STDOUT_FILENO) >= 0);
    char *arguments[] = {"capsnowd", "--log", NULL};
    assert(capsnowAgentMain(2, arguments) == 0);
    DIAG(@"agent start");
    assert(capsnowAgentMain(2, arguments) == 0);
    fflush(stdout);
    assert(dup2(saved, STDOUT_FILENO) >= 0);
    close(saved);
    rewind(output);
    char text[256];
    assert(fgets(text, sizeof(text), output));
    assert(!strcmp(text, "Diagnostic log (local times, oldest first):\n"));
    assert(fgets(text, sizeof(text), output));
    assert(!strcmp(text, "No entries in the last 5 minutes.\n"));
    assert(fgets(text, sizeof(text), output));
    assert(!strcmp(text, "Diagnostic log (local times, oldest first):\n"));
    assert(fgets(text, sizeof(text), output));
    assert(strstr(text, " agent start\n"));
    assert(!fgets(text, sizeof(text), output));
    assert(testWrites == 0);
    fclose(output);
    CFNotificationCenterRemoveEveryObserver(center, NULL);
}
#endif

static void testActions(void) {
#ifdef CAPSNOW_DIAGNOSTIC_LOG
    resetLog();
#endif
    applyNoDelay();
    assert(testDelay == 0 && testWrites == 1);
#ifdef CAPSNOW_DIAGNOSTIC_LOG
    NSArray *entries = diagnosticRead();
    assert(entries.count == 2);
    assert([entries[0][@"text"] isEqual:@"set Caps Lock delay override=0 ms"]);
    assert([entries[1][@"text"] isEqual:@"Caps Lock delay override accepted=0 ms"]);

    resetLog();
#endif
    removeOverride();
    assert(testDelay == NO_OVERRIDE && testWrites == 2);
#ifdef CAPSNOW_DIAGNOSTIC_LOG
    entries = diagnosticRead();
    assert(entries.count == 2);
    assert([entries[1][@"text"] isEqual:@"Caps Lock delay override accepted=-1 ms"]);

    resetLog();
#endif
    testWriteAccepted = NO;
    FILE *output = tmpfile();
    assert(output);
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    assert(saved >= 0 && dup2(fileno(output), STDERR_FILENO) >= 0);
    applyNoDelay();
    fflush(stderr);
    long helperOutputSize = ftell(output);
#ifdef CAPSNOW_DIAGNOSTIC_LOG
    entries = diagnosticRead();
    assert(testWrites == 3 && entries.count == 2);
    assert([entries[1][@"text"] isEqual:@"could not set the Caps Lock delay"]);
#endif
    char *arguments[] = {"capsnowd", "--off", NULL};
    assert(capsnowAgentMain(2, arguments) == 0);
    assert(testDelay == NO_OVERRIDE && testWrites == 4);
    fflush(stderr);
    assert(dup2(saved, STDERR_FILENO) >= 0);
    close(saved);
    assert(helperOutputSize == 0);
    rewind(output);
    char text[256];
    assert(fgets(text, sizeof(text), output));
    assert(!strcmp(text, "capsnowd: could not set the Caps Lock delay\n"));
    assert(!fgets(text, sizeof(text), output));
    fclose(output);
    testWriteAccepted = YES;
}

int main(void) {
    @autoreleasepool {
#ifdef CAPSNOW_DIAGNOSTIC_LOG
        testRing();
        testReply();
        testPrint();
        testActions();
        testLifetime();
        puts("Passed diagnostic checks: ring capacity, age pruning, request/reply, log output, delay actions and errors, idle lifetime.");
#else
        testActions();
        puts("Passed release checks: delay actions and errors.");
#endif
    }
    return 0;
}
