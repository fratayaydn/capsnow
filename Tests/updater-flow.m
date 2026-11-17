// All requests and preferences stay in memory; the bundle is a private fixture.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <mach-o/dyld.h>

static NSMutableDictionary *preferences;
static NSDictionary *releaseFixture;
static NSString *executableFixture;
static int checks, downloads;
static BOOL requestFails, saveFails;
static id<NSURLSessionTaskDelegate> releaseDelegate;

static Boolean fixtureSynchronize(CFStringRef domain) {
    assert(CFEqual(domain, CFSTR("io.github.fratayaydn.capsnow")));
    return !saveFails;
}

static void fixtureSet(CFStringRef key, CFPropertyListRef value, CFStringRef domain) {
    assert(CFEqual(domain, CFSTR("io.github.fratayaydn.capsnow")));
    assert(CFEqual(key, CFSTR("LatestVersion")));
    preferences[(__bridge NSString *)key] = (__bridge id)value;
}

static int fixtureExecutablePath(char *buffer, uint32_t *size) {
    uint32_t required = (uint32_t)strlen(executableFixture.fileSystemRepresentation) + 1;
    if (*size < required) { *size = required; return -1; }
    memcpy(buffer, executableFixture.fileSystemRepresentation, required);
    return 0;
}

@interface FixtureTask : NSObject
@property(copy) void (^completion)(void);
- (void)resume;
@end
@implementation FixtureTask
- (void)resume { self.completion(); }
@end

@interface FixtureSession : NSObject
- (FixtureTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (FixtureTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completion;
- (void)invalidateAndCancel;
@end

@implementation FixtureSession
- (FixtureTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    checks++;
    assert([request.URL.absoluteString isEqual:@"https://api.github.com/repos/fratayaydn/capsnow/releases/latest"]);
    assert([[request valueForHTTPHeaderField:@"User-Agent"] isEqual:@"CapsNow/1.0.0"]);
    FixtureTask *task = [FixtureTask new];
    task.completion = ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:releaseFixture options:0 error:NULL];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        completion(data, response, requestFails ? [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil] : nil);
    };
    return task;
}
- (FixtureTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completion {
    downloads++;
    FixtureTask *task = [FixtureTask new];
    task.completion = ^{ completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]); };
    return task;
}
- (void)invalidateAndCancel {}
@end

@interface NSURLSession (Fixture)
+ (NSURLSession *)fixtureSessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
+ (NSURLSession *)fixtureSessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue;
@end
@implementation NSURLSession (Fixture)
+ (NSURLSession *)fixtureSessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    return [self fixtureSessionWithConfiguration:configuration delegate:nil delegateQueue:nil];
}
+ (NSURLSession *)fixtureSessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    assert(configuration.HTTPCookieStorage == nil && !configuration.HTTPShouldSetCookies);
    assert(configuration.URLCache == nil && configuration.URLCredentialStorage == nil);
    releaseDelegate = (id<NSURLSessionTaskDelegate>)delegate;
    return (NSURLSession *)[FixtureSession new];
}
@end

#define CFPreferencesAppSynchronize fixtureSynchronize
#define CFPreferencesSetAppValue fixtureSet
#define _NSGetExecutablePath fixtureExecutablePath
#define sessionWithConfiguration fixtureSessionWithConfiguration
#import "../Sources/Updater/Updater.m"
#define main updaterMain
#import "../Sources/Updater/main.m"
#undef main

static int run(NSString *mode, NSString *tag) {
    checks = downloads = 0;
    releaseFixture = @{@"tag_name": tag, @"draft": @NO, @"prerelease": @NO,
        @"assets": @[@{@"name": @"CapsNow-1.1.0.dmg", @"size": @100,
                       @"browser_download_url": @"https://github.com/fratayaydn/capsnow/releases/download/v1.1.0/CapsNow-1.1.0.dmg"}]};
    char *arguments[] = {"capsnow-update", (char *)mode.UTF8String, NULL};
    return updaterMain(2, arguments);
}

int main(void) {
    @autoreleasepool {
        preferences = [NSMutableDictionary new];
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *contents = [root stringByAppendingPathComponent:@"CapsNow.app/Contents"];
        NSFileManager *fm = NSFileManager.defaultManager;
        assert([fm createDirectoryAtPath:[contents stringByAppendingPathComponent:@"MacOS"] withIntermediateDirectories:YES attributes:nil error:NULL]);
        executableFixture = [contents stringByAppendingPathComponent:@"MacOS/capsnow-update"];
        assert([fm createFileAtPath:executableFixture contents:NSData.data attributes:nil]);
        assert(([@{@"CFBundleShortVersionString": @"1.0.0"} writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] atomically:YES]));
        @try {
            assert(run(@"--check", @"v1.1.0") == 0);
            assert(checks == 1 && downloads == 0);
            assert([preferences[@"LatestVersion"] isEqual:@"1.1.0"]);
            assert(releaseDelegate != nil);
            NSURL *api = [NSURL URLWithString:@"https://api.github.com/repos/fratayaydn/capsnow/releases/latest"];
            NSHTTPURLResponse *redirect = [[NSHTTPURLResponse alloc] initWithURL:api statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:nil];
            NSURLRequest *next = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://github.com/redirect"]];
            __block BOOL rejected = NO;
            [releaseDelegate URLSession:(id)[NSObject new] task:(id)[NSObject new] willPerformHTTPRedirection:redirect newRequest:next completionHandler:^(NSURLRequest *request) {
                rejected = request == nil;
            }];
            assert(rejected);
            assert(run(@"--install", @"v1.1.0") != 0);
            assert(checks == 1 && downloads == 1);
            assert([preferences[@"LatestVersion"] isEqual:@"1.1.0"]);
            for (NSString *tag in @[@"1.0.0", @"0.9.0"]) {
                assert(run(@"--check", tag) == 0 && checks == 1 && downloads == 0);
                assert(run(@"--install", tag) != 0 && checks == 1 && downloads == 0);
            }
            assert(run(@"--check", @"invalid") != 0 && downloads == 0);
            requestFails = YES;
            assert(run(@"--check", @"1.1.0") != 0 && checks == 1 && downloads == 0);
            requestFails = NO;
            saveFails = YES;
            assert(run(@"--install", @"1.1.0") != 0 && downloads == 0);
            saveFails = NO;
            assert(run(@"--automatic", @"1.1.0") != 0 && checks == 0 && downloads == 0);
            char *arguments[] = {"capsnow-update", NULL};
            assert(updaterMain(1, arguments) != 0 && checks == 0 && downloads == 0);
            puts("Passed updater flow checks: one release request, saved version, check never downloads or installs, only explicit install downloads, failures and invalid modes.");
        } @finally {
            assert([fm removeItemAtPath:root error:NULL]);
        }
    }
    return 0;
}
