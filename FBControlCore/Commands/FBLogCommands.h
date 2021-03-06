/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol FBFileConsumer;
@protocol FBTerminationHandle;

/**
 Commands for obtaining logs.
 */
@protocol FBLogCommands <NSObject>

/**
 Starts tailing the log of a Simulator to a consumer.

 @param arguments the arguments for the log command.
 @param consumer the consumer to attach
 @param error an error out for any error that occurs.
 @return a Termination Handle if successful, nil otherwise.
 */
- (nullable id<FBTerminationHandle>)tailLog:(NSArray<NSString *> *)arguments consumer:(id<FBFileConsumer>)consumer error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
