// Only loaded into the two ghost-benchmark processes by motion_probe.rb.
// Invisible accessory windows may be App Napped, coalescing both Ruby's timers
// and the renderer's frame deadlines. Measure them as an active UI workload,
// without activating a window or preventing display/system sleep.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static id activity;

__attribute__((constructor)) static void begin_motion_measurement(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    @autoreleasepool {
        NSActivityOptions options = NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical;
        activity = [[[NSProcessInfo processInfo] beginActivityWithOptions:options
            reason:@"Aljam3 ghost-window motion benchmark"] retain];
        fprintf(stderr, "[motion-benchmark] active scheduling in process %d\n", getpid());
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
