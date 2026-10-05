// Sparkle installs a locally cached, Ed25519-signed archive after Ruby has quit.
// A loopback server is necessary because Sparkle deliberately rejects file URLs.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <signal.h>
#include <unistd.h>

static NSString *appPath, *resultPath;
static void finish(int code) {
    [(code == 0 ? @"installed" : @"failed") writeToFile:resultPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/open";
    NSMutableArray *arguments = [NSMutableArray array];
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    if (environment[@"ALJAM3_DATA_DIR"]) [arguments addObjectsFromArray:@[@"--env", [@"ALJAM3_DATA_DIR=" stringByAppendingString:environment[@"ALJAM3_DATA_DIR"]]]];
    if ([environment[@"GITHUB_ACTIONS"] isEqualToString:@"true"]) {
        for (NSString *key in @[@"SCARPE_RUN_FILE", @"SCARPE_NATIVE_HEADLESS", @"ALJAM3_VERIFY_OUTPUT", @"ALJAM3_API_URL", @"ALJAM3_UPGRADE_MANIFEST", @"ALJAM3_UPGRADE_PACKAGE", @"ALJAM3_UPGRADE_SENTINEL"]) {
            if (environment[key]) [arguments addObjectsFromArray:@[@"--env", [NSString stringWithFormat:@"%@=%@", key, environment[key]]]];
        }
    }
    [arguments addObject:appPath];
    task.arguments = arguments;
    [task launchAndReturnError:nil];
    exit(code);
}

@interface UpdateDriver : NSObject <SPUUserDriver, SPUUpdaterDelegate>
@property NSString *feed;
@property SPUUpdater *updater;
@end
@implementation UpdateDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:YES sendSystemProfile:NO]);
}
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { return NO; }
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return self.feed; }
- (BOOL)updater:(SPUUpdater *)updater shouldDownloadReleaseNotesForUpdate:(SUAppcastItem *)item { return NO; }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancel {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack { ack(); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"Update failed: %@", error); ack(); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancel {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate {}
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { ack(); }
- (void)dismissUpdateInstallation {}
- (void)showUpdateInFocus {}
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    if (error) NSLog(@"Sparkle: %@", error);
    finish(error ? 1 : 0);
}
@end

static NSString *serve(NSString *archive, NSString *version, NSString *signature) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 4)) return nil;
    socklen_t length = sizeof(address);
    getsockname(listener, (struct sockaddr *)&address, &length);
    NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%d", ntohs(address.sin_port)];
    unsigned long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:archive error:nil] fileSize];
    NSData *feed = [[NSString stringWithFormat:@"<?xml version=\"1.0\"?><rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><title>Aljam3</title><item><title>Aljam3 %@</title><sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion><enclosure url=\"%@/update.zip\" sparkle:version=\"%@\" sparkle:shortVersionString=\"%@\" sparkle:edSignature=\"%@\" length=\"%llu\" type=\"application/octet-stream\"/></item></channel></rss>", version, base, version, version, signature, size] dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (YES) {
            int client = accept(listener, NULL, NULL);
            if (client < 0) break;
            struct timeval timeout = { 10, 0 };
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            char request[4096] = {0};
            ssize_t received = recv(client, request, sizeof(request) - 1, 0);
            BOOL isFeed = received > 0 && strncmp(request, "GET /feed.xml ", 14) == 0;
            BOOL isArchive = received > 0 && strncmp(request, "GET /update.zip ", 16) == 0;
            FILE *stream = fdopen(client, "w");
            if (!stream) { close(client); continue; }
            if (isFeed || isArchive) {
                fprintf(stream, "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %llu\r\nConnection: close\r\n\r\n", isFeed ? "application/xml" : "application/octet-stream", isFeed ? (unsigned long long)feed.length : size);
                if (isFeed) fwrite(feed.bytes, 1, feed.length, stream);
                else {
                    FILE *file = fopen(archive.fileSystemRepresentation, "rb");
                    char buffer[65536]; size_t count;
                    if (file) { while ((count = fread(buffer, 1, sizeof(buffer), file)) && fwrite(buffer, 1, count, stream) == count) {} fclose(file); }
                }
            } else fprintf(stream, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            fclose(stream);
        }
    });
    return [base stringByAppendingString:@"/feed.xml"];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 7) return 2;
        signal(SIGPIPE, SIG_IGN);
        appPath = @(argv[1]); resultPath = @(argv[6]);
        pid_t parent = atoi(argv[5]);
        for (int i = 0; parent > 0 && kill(parent, 0) == 0; i++) {
            if (i >= 1200) { NSLog(@"Application did not quit; no files changed"); return 1; }
            usleep(100000);
        }
        UpdateDriver *driver = [UpdateDriver new];
        driver.feed = serve(@(argv[2]), @(argv[3]), @(argv[4]));
        if (!driver.feed) finish(1);
        NSBundle *bundle = [NSBundle bundleWithPath:appPath];
        driver.updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:driver delegate:driver];
        NSError *error = nil;
        if (![driver.updater startUpdater:&error]) { NSLog(@"%@", error); finish(1); }
        [driver.updater checkForUpdates];
        [[NSRunLoop currentRunLoop] run];
    }
    return 1;
}
