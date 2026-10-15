#import <Foundation/Foundation.h>
#import "SPUUpdateDriver.h"
#import "SPUUIBasedUpdateDriver.h"
#import "SPUCoreBasedUpdateDriver.h"

static BOOL equalHeaders(id actual, id expected) {
    return actual == expected || [actual isEqual:expected];
}

int main(void) {
    @autoreleasepool {
        NSUInteger checked = 0;
        for (NSString *name in @[@"SPUUserInitiatedUpdateDriver", @"SPUScheduledUpdateDriver"]) {
            id<SPUUpdateDriver> driver = [NSClassFromString(name) new];
            SPUUIBasedUpdateDriver *ui = [NSClassFromString(@"SPUUIBasedUpdateDriver") new];
            SPUCoreBasedUpdateDriver *core = [NSClassFromString(@"SPUCoreBasedUpdateDriver") new];
            [(NSObject *)driver setValue:ui forKey:@"uiDriver"];
            [ui setValue:core forKey:@"coreDriver"];
            // Stop at the basic-driver boundary; no appcast, installer or UI starts.
            [core setValue:nil forKey:@"basicDriver"];
            for (id policy in @[@{@"X-Solstone-Update-Origin": @"https://a.invalid/feed"}, @{@"X-Solstone-Update-Origin": @"https://b.invalid/feed"}, NSNull.null]) {
                NSDictionary *headers = policy == NSNull.null ? nil : policy;
                [driver resumeUpdate:(id<SPUResumableUpdate>)[NSObject new] httpHeaders:headers];
                if (!equalHeaders([ui valueForKey:@"httpHeaders"], headers) || !equalHeaders([core valueForKey:@"httpHeaders"], headers)) return 1;
                checked++;
                [driver resumeInstallingUpdateWithHTTPHeaders:headers];
                if (!equalHeaders([ui valueForKey:@"httpHeaders"], headers) || !equalHeaders([core valueForKey:@"httpHeaders"], headers)) return 2;
                checked++;
            }
        }
        printf("{\"resume_policy_cases\":%lu,\"pass\":true}\n", (unsigned long)checked);
    }
    return 0;
}
