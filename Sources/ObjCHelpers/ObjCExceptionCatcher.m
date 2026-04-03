// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Unknown exception",
                @"ExceptionName": exception.name ?: @"Unknown",
            };
            *error = [NSError errorWithDomain:@"ObjCException" code:1 userInfo:userInfo];
        }
        return NO;
    }
}

@end
