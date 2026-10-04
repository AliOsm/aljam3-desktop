// Only injected into the two ghost-benchmark processes by PackageVerification.
// Invisible accessory windows may be App Napped, coalescing both Ruby's timers
// and the renderer's frame deadlines. Measure them as an active UI workload,
// without activating a window or preventing display/system sleep.
#import <Foundation/Foundation.h>

static id activity;

__attribute__((constructor)) static void begin_motion_measurement(void) {
    @autoreleasepool {
        NSActivityOptions options = NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical;
        activity = [[[NSProcessInfo processInfo] beginActivityWithOptions:options
            reason:@"Aljam3 ghost-window motion benchmark"] retain];
    }
}

__attribute__((destructor)) static void end_motion_measurement(void) {
    @autoreleasepool {
        if (activity) {
            [[NSProcessInfo processInfo] endActivity:activity];
            [activity release];
        }
    }
}
