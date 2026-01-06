// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Helper to catch Objective-C exceptions and convert them to NSError
@interface ObjCExceptionCatcher : NSObject

/// Execute a block and catch any NSException, converting to NSError
/// @param block The block to execute
/// @param error On return, contains an NSError if an exception was thrown
/// @return YES if block executed without exception, NO otherwise
+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
