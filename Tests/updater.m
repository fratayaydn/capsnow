// Release policy checks do not start a session, mount an image or change saved preferences.
#import "../Sources/Updater/Updater.h"
#import <Security/Security.h>
#include <assert.h>
#include <limits.h>

static void versions(void) {
    assert([updaterVersion(@"v1.2.3") isEqual:@"1.2.3"]);
    assert(!updaterVersion(nil) && !updaterVersion(@123));
    for (NSString *invalid in @[@"", @"v", @"1..2", @"1.2.3.4", @"1.2-beta", @"1/2", @"-1.0", @"1. 2"])
        assert(!updaterVersion(invalid));
    assert(updaterCompareVersions(@"1.10.0", @"1.9.9") == NSOrderedDescending);
    assert(updaterCompareVersions(@"v2.0.0", @"1.99.99") == NSOrderedDescending);
    assert(updaterCompareVersions(@"1.2.4", @"1.2.3") == NSOrderedDescending);
    assert(updaterCompareVersions(@"1.2.3", @"1.2.4") == NSOrderedAscending);
    assert(updaterCompareVersions(@"v1.2.3", @"1.2.3") == NSOrderedSame);
    assert(updaterCompareVersions(@"1.2", @"1.2.0") == NSOrderedSame);
    assert(updaterCompareVersions(@"1", @"1.0.0") == NSOrderedSame);
    assert(updaterCompareVersions(@"1.0002.3", @"1.2.3") == NSOrderedSame);
    assert(updaterCompareVersions(@"1.999999999999999999999999.0", @"1.10.0") == NSOrderedDescending);
}

static void assetSizes(void) {
    assert(updaterAssetSizeValid(@1));
    assert(updaterAssetSizeValid(@(64 * 1024 * 1024)));
    assert(!updaterAssetSizeValid(nil));
    for (id invalid in @[NSNull.null, @"123", @0, @-1, @0.5, @(64 * 1024 * 1024 + 1), @(ULLONG_MAX)])
        assert(!updaterAssetSizeValid(invalid));
}

int main(void) {
    @autoreleasepool {
        versions();
        assetSizes();
        assert([updaterAssetName(@"1.2.3") isEqual:@"CapsNow-1.2.3.dmg"]);
        NSString *requirement = updaterRequirement();
        assert([requirement isEqual:@"anchor apple generic and identifier \"io.github.fratayaydn.capsnow\" "
                                    "and certificate leaf[subject.OU] = \"GYWRX9QZZD\" and notarized"]);
        SecRequirementRef compiled = NULL;
        assert(SecRequirementCreateWithString((__bridge CFStringRef)requirement, kSecCSDefaultFlags, &compiled) == errSecSuccess);
        CFRelease(compiled);
        puts("Passed updater checks: numeric versions, asset name, size limits and notarized developer requirement; no network access.");
    }
    return 0;
}
