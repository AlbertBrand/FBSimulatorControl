/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBSimulatorEventRelay.h"

#import <Cocoa/Cocoa.h>

#import <CoreSimulator/SimDevice.h>

#import <FBControlCore/FBControlCore.h>

#import "FBCoreSimulatorNotifier.h"
#import "FBSimulatorAgentOperation.h"
#import "FBSimulatorConnection.h"
#import "FBSimulatorProcessFetcher.h"

@interface FBSimulatorEventRelay ()

@property (nonatomic, copy, readwrite) FBProcessInfo *launchdProcess;
@property (nonatomic, copy, readwrite) FBProcessInfo *containerApplication;
@property (nonatomic, strong, readwrite) FBSimulatorConnection *connection;

@property (nonatomic, assign, readwrite) FBSimulatorState lastKnownState;
@property (nonatomic, strong, readonly) NSMutableSet *knownLaunchedProcesses;

@property (nonatomic, strong, readonly) id<FBSimulatorEventSink> sink;
@property (nonatomic, strong, readonly) FBSimulatorProcessFetcher *processFetcher;
@property (nonatomic, strong, readonly) SimDevice *simDevice;

@property (nonatomic, strong, readonly) NSMutableDictionary *processTerminationNotifiers;
@property (nonatomic, strong, readwrite) FBCoreSimulatorNotifier *stateChangeNotifier;

@end

@implementation FBSimulatorEventRelay

- (instancetype)initWithSimDevice:(SimDevice *)simDevice launchdProcess:(nullable FBProcessInfo *)launchdProcess containerApplication:(nullable FBProcessInfo *)containerApplication processFetcher:(FBSimulatorProcessFetcher *)processFetcher sink:(id<FBSimulatorEventSink>)sink
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _sink = sink;
  _simDevice = simDevice;
  _processFetcher = processFetcher;

  _processTerminationNotifiers = [NSMutableDictionary dictionary];
  _knownLaunchedProcesses = [NSMutableSet set];
  _lastKnownState = FBSimulatorStateUnknown;

  _launchdProcess = launchdProcess;
  _containerApplication = containerApplication;

  [self registerSimulatorLifecycleHandlers];
  [self createNotifierForSimDevice:simDevice];

  return self;
}

- (void)dealloc
{
  [self unregisterAllNotifiers];
  [self unregisterSimulatorLifecycleHandlers];
}

#pragma mark FBSimulatorEventSink Protocol Implementation

- (void)containerApplicationDidLaunch:(FBProcessInfo *)applicationProcess
{
  NSParameterAssert(applicationProcess);

  // If we have Application-centric Launch Info, deduplicate.
  if (self.containerApplication) {
    return;
  }
  self.containerApplication = applicationProcess;
  [self.sink containerApplicationDidLaunch:applicationProcess];
}

- (void)containerApplicationDidTerminate:(FBProcessInfo *)applicationProcess expected:(BOOL)expected
{
  NSParameterAssert(applicationProcess);

  // De-duplicate known-terminated Simulators.
  if (!self.containerApplication) {
    return;
  }
  self.containerApplication = nil;
  [self.sink containerApplicationDidTerminate:applicationProcess expected:expected];
}

- (void)connectionDidConnect:(FBSimulatorConnection *)connection
{
  NSParameterAssert(connection);
  NSParameterAssert(self.connection == nil);

  self.connection = connection;
  [self.sink connectionDidConnect:connection];
}

- (void)connectionDidDisconnect:(FBSimulatorConnection *)connection expected:(BOOL)expected
{
  NSParameterAssert(connection);
  NSParameterAssert(self.connection);

  self.connection = nil;
  [self.sink connectionDidDisconnect:connection expected:expected];
}

- (void)simulatorDidLaunch:(FBProcessInfo *)launchdProcess
{
  NSParameterAssert(launchdProcess);

  // De-duplicate known-launched launchd_sims.
  if (self.launchdProcess) {
    return;
  }
  self.launchdProcess = launchdProcess;
  [self.sink simulatorDidLaunch:launchdProcess];
}

- (void)simulatorDidTerminate:(FBProcessInfo *)launchdProcess expected:(BOOL)expected
{
  NSParameterAssert(launchdProcess);

  // De-duplicate known-terminated launchd_sims.
  if (!self.launchdProcess) {
    return;
  }
  self.launchdProcess = nil;
  [self.sink simulatorDidTerminate:launchdProcess expected:expected];
}

- (void)agentDidLaunch:(FBSimulatorAgentOperation *)operation
{
  // De-duplicate known-launched agents.
  FBProcessInfo *agentProcess = operation.process;
  if ([self.knownLaunchedProcesses containsObject:agentProcess]) {
    return;
  }

  [self.knownLaunchedProcesses addObject:agentProcess];
  [self.sink agentDidLaunch:operation];
}

- (void)agentDidTerminate:(FBSimulatorAgentOperation *)operation statLoc:(int)statLoc
{
  if (![self.knownLaunchedProcesses containsObject:operation.process]) {
    return;
  }

  [self.sink agentDidTerminate:operation statLoc:statLoc];
}

- (void)applicationDidLaunch:(FBApplicationLaunchConfiguration *)launchConfig didStart:(FBProcessInfo *)applicationProcess
{
  // De-duplicate known-launched applications.
  if ([self.knownLaunchedProcesses containsObject:applicationProcess]) {
    return;
  }

  [self.knownLaunchedProcesses addObject:applicationProcess];
  [self createNotifierForProcess:applicationProcess withHandler:^(FBSimulatorEventRelay *relay) {
    [relay applicationDidTerminate:applicationProcess expected:NO];
  }];
  [self.sink applicationDidLaunch:launchConfig didStart:applicationProcess];
}

- (void)applicationDidTerminate:(FBProcessInfo *)applicationProcess expected:(BOOL)expected
{
  if (![self.knownLaunchedProcesses containsObject:applicationProcess]) {
    return;
  }

  [self.knownLaunchedProcesses removeObject:applicationProcess];
  [self unregisterNotifierForProcess:applicationProcess];
  [self.sink applicationDidTerminate:applicationProcess expected:expected];
}

- (void)testmanagerDidConnect:(FBTestManager *)testManager
{
  [self.sink testmanagerDidConnect:testManager];
}

- (void)testmanagerDidDisconnect:(FBTestManager *)testManager
{
  [self.sink testmanagerDidDisconnect:testManager];
}

- (void)diagnosticAvailable:(FBDiagnostic *)diagnostic
{
  [self.sink diagnosticAvailable:diagnostic];
}

- (void)didChangeState:(FBSimulatorState)state
{
  if (state == self.lastKnownState) {
    return;
  }
  if (state == FBSimulatorStateBooted) {
    [self fetchLaunchdSimInfoFromBoot];
  }
  if (state == FBSimulatorStateShutdown || state == FBSimulatorStateShuttingDown) {
    [self discardLaunchdSimInfoFromBoot];
  }

  self.lastKnownState = state;
  [self.sink didChangeState:state];
}

- (void)terminationHandleAvailable:(id<FBTerminationHandle>)terminationHandle
{
  [self.sink terminationHandleAvailable:terminationHandle];
}

#pragma mark Private

#pragma mark Process Termination

- (void)createNotifierForProcess:(FBProcessInfo *)process withHandler:( void(^)(FBSimulatorEventRelay *relay) )handler
{
  NSParameterAssert(self.processTerminationNotifiers[process] == nil);

  __weak typeof(self) weakSelf = self;
  FBDispatchSourceNotifier *notifier = [FBDispatchSourceNotifier processTerminationNotifierForProcessIdentifier:process.processIdentifier handler:^(FBDispatchSourceNotifier *_) {
    handler(weakSelf);
  }];
  self.processTerminationNotifiers[process] = notifier;
}

- (void)unregisterNotifierForProcess:(FBProcessInfo *)process
{
  FBDispatchSourceNotifier *notifier = self.processTerminationNotifiers[process];
  if (!notifier) {
    return;
  }
  [notifier terminate];
  [self.processTerminationNotifiers removeObjectForKey:process];
}

- (void)unregisterAllNotifiers
{
  [self.processTerminationNotifiers.allValues makeObjectsPerformSelector:@selector(terminate)];
  [self.processTerminationNotifiers removeAllObjects];
  [self.stateChangeNotifier terminate];
  self.stateChangeNotifier = nil;
}

#pragma mark State Notifier

- (void)createNotifierForSimDevice:(SimDevice *)device
{
  __weak typeof(self) weakSelf = self;
  self.stateChangeNotifier = [FBCoreSimulatorNotifier notifierForSimDevice:device block:^(NSDictionary *info) {
    NSNumber *newStateNumber = info[@"new_state"];
    if (!newStateNumber) {
      return;
    }
    [weakSelf didChangeState:newStateNumber.unsignedIntegerValue];
  }];
}

#pragma mark Updating Launch Info from CoreSimulator Notifications

- (void)fetchLaunchdSimInfoFromBoot
{
  // We already have launchd_sim info, don't bother fetching.
  if (self.launchdProcess) {
    return;
  }

  FBProcessInfo *launchdSim = [self.processFetcher launchdProcessForSimDevice:self.simDevice];
  if (!launchdSim) {
    return;
  }
  [self simulatorDidLaunch:launchdSim];
}

- (void)discardLaunchdSimInfoFromBoot
{
  // Don't look at the application if we know if we don't consider the Simulator boot.
  if (!self.launchdProcess) {
    return;
  }

  // Notify of Simulator Termination.
  [self simulatorDidTerminate:self.launchdProcess expected:NO];
}

#pragma mark Simulator Application Launch/Termination

- (void)registerSimulatorLifecycleHandlers
{
  [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(workspaceApplicationDidLaunch:) name:NSWorkspaceDidLaunchApplicationNotification object:nil];
  [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(workspaceApplicationDidTerminate:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];
}

- (void)unregisterSimulatorLifecycleHandlers
{
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceDidLaunchApplicationNotification object:nil];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceDidTerminateApplicationNotification object:nil];
}

- (void)workspaceApplicationDidLaunch:(NSNotification *)notification
{
  // Don't fetch Container Application info if we already have it
  if (self.containerApplication) {
    return;
  }

  // The Application must contain the FBSimulatorControlSimulatorLaunchEnvironmentSimulatorUDID key in the environment
  // This Environment Variable exists to allow interested parties to know the UDID of the Launched Simulator,
  // without having to inspect the Simulator Application's launchd_sim first.
  NSRunningApplication *launchedApplication = notification.userInfo[NSWorkspaceApplicationKey];
  FBProcessInfo *simulatorProcess = [self.processFetcher.processFetcher processInfoFor:launchedApplication.processIdentifier];
  if (![simulatorProcess.environment[FBSimulatorControlSimulatorLaunchEnvironmentSimulatorUDID] isEqual:self.simDevice.UDID.UUIDString]) {
    return;
  }

  [self containerApplicationDidLaunch:simulatorProcess];
}

- (void)workspaceApplicationDidTerminate:(NSNotification *)notification
{
  // Don't look at the application if we know if we don't consider the Simulator launched.
  if (!self.containerApplication) {
    return;
  }

  // See if the terminated application is the same as the launch info.
  NSRunningApplication *terminatedApplication = notification.userInfo[NSWorkspaceApplicationKey];
  if (terminatedApplication.processIdentifier != self.containerApplication.processIdentifier) {
    return;
  }

  // Notify of Simulator Termination.
  [self containerApplicationDidTerminate:self.containerApplication expected:NO];
}

@end
