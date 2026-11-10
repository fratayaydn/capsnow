#ifdef CAPSNOW_DIAGNOSTIC_LOG

#define DIAG(...) diagnosticAdd([NSString stringWithFormat:__VA_ARGS__])
#define LOG_REQUEST CFSTR("io.github.fratayaydn.capsnow.LogRequest")
#define LOG_REPLY CFSTR("io.github.fratayaydn.capsnow.LogReply")

// All access is on the main run loop. Entries contain only timestamps and short event text.
static NSDictionary *gDiagnosticEntries[500];
static NSUInteger gDiagnosticHead, gDiagnosticCount;

static void diagnosticPrune(CFAbsoluteTime now) {
    while (gDiagnosticCount &&
           [gDiagnosticEntries[gDiagnosticHead][@"timestamp"] doubleValue] < now - 300) {
        gDiagnosticEntries[gDiagnosticHead] = nil;
        gDiagnosticHead = (gDiagnosticHead + 1) % 500;
        gDiagnosticCount--;
    }
}

static void diagnosticAdd(NSString *text) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    diagnosticPrune(now);
    if (gDiagnosticCount == 500) {
        gDiagnosticEntries[gDiagnosticHead] = nil;
        gDiagnosticHead = (gDiagnosticHead + 1) % 500;
        gDiagnosticCount--;
    }
    gDiagnosticEntries[(gDiagnosticHead + gDiagnosticCount++) % 500] =
        @{@"timestamp": @(now), @"text": text};
}

static NSArray *diagnosticRead(void) {
    diagnosticPrune(CFAbsoluteTimeGetCurrent());
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:gDiagnosticCount];
    for (NSUInteger i = 0; i < gDiagnosticCount; i++)
        [entries addObject:gDiagnosticEntries[(gDiagnosticHead + i) % 500]];
    return entries;
}

static void diagnosticRequested(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                const void *object, CFDictionaryRef info) {
    if (!object) return;
    NSDictionary *reply = @{@"entries": diagnosticRead()};
    CFNotificationCenterPostNotification(center, LOG_REPLY, object, (__bridge CFDictionaryRef)reply, true);
}

static void diagnosticReceived(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                               const void *object, CFDictionaryRef info) {
    NSArray *__strong *entries = (NSArray *__strong *)observer;
    id value = ((__bridge NSDictionary *)info)[@"entries"];
    if ([value isKindOfClass:NSArray.class]) *entries = value;
}

static int diagnosticPrint(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetDistributedCenter();
    NSString *token = NSUUID.UUID.UUIDString;
    NSArray *entries = nil;
    CFNotificationCenterAddObserver(center, &entries, diagnosticReceived, LOG_REPLY,
                                    (__bridge CFStringRef)token, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, (__bridge CFStringRef)token, NULL, true);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 2;
    while (!entries && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    CFNotificationCenterRemoveObserver(center, &entries, LOG_REPLY, (__bridge CFStringRef)token);
    if (!entries) {
        fprintf(stderr, "capsnowd: diagnostic agent did not answer\n");
        return 1;
    }
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS zzz";
    puts("Diagnostic log (local times, oldest first):");
    if (!entries.count) puts("No entries in the last 5 minutes.");
    for (NSDictionary *entry in entries) {
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:[entry[@"timestamp"] doubleValue]];
        printf("%s %s\n", [formatter stringFromDate:date].UTF8String, [entry[@"text"] UTF8String]);
    }
    return 0;
}

#else
#define DIAG(...) ((void)0)
#endif
