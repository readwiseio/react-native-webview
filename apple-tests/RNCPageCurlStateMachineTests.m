#import <XCTest/XCTest.h>
#import "RNCPageCurlStateMachine.h"

static NSDictionary *Settle(NSInteger page, NSInteger chunk)
{
  return @{@"type": @"settled", @"page": @(page), @"totalPages": @10, @"chunkIndex": @(chunk), @"isLastChunk": @NO};
}

// one line per effect the controller has to carry out; notes are log lines only
static NSArray<NSString *> *Describe(NSArray<RNCPageCurlEffect *> *effects)
{
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (RNCPageCurlEffect *effect in effects) {
    switch (effect.kind) {
      case RNCPageCurlEffectEnterState:
        [lines addObject:[NSString stringWithFormat:@"state %@ (%@)", RNCPageCurlStateName(effect.state), effect.reason]];
        break;
      case RNCPageCurlEffectBake:
        [lines addObject:[NSString stringWithFormat:@"bake page %@ chunk %@", effect.settle[@"page"], effect.settle[@"chunkIndex"]]];
        break;
      case RNCPageCurlEffectBlankSlots:
        [lines addObject:@"blank slots"];
        break;
      case RNCPageCurlEffectShowLandedPage:
        [lines addObject:[NSString stringWithFormat:@"show landed %@", effect.direction]];
        break;
      case RNCPageCurlEffectShowCurrentPage:
        [lines addObject:@"show current"];
        break;
      case RNCPageCurlEffectLand:
        [lines addObject:[NSString stringWithFormat:@"land %@", effect.direction]];
        break;
      case RNCPageCurlEffectRequestSettle:
        [lines addObject:@"request settle"];
        break;
      case RNCPageCurlEffectNote:
        break;
    }
  }
  return lines;
}

// the token of the settle request in `effects`, or 0 when there is none
static NSUInteger SettleRequestToken(NSArray<RNCPageCurlEffect *> *effects)
{
  for (RNCPageCurlEffect *effect in effects) {
    if (effect.kind == RNCPageCurlEffectRequestSettle) {
      return effect.token;
    }
  }
  return 0;
}

static BOOL Contains(NSArray<RNCPageCurlEffect *> *effects, RNCPageCurlEffectKind kind)
{
  for (RNCPageCurlEffect *effect in effects) {
    if (effect.kind == kind) {
      return YES;
    }
  }
  return NO;
}

@interface RNCPageCurlStateMachineTests : XCTestCase
@end

@implementation RNCPageCurlStateMachineTests {
  RNCPageCurlStateMachine *_machine;
}

- (void)setUp
{
  _machine = [RNCPageCurlStateMachine new];
}

// enabled, first page baked, idle
- (void)bakeFirstPage
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:YES];
}

// first page baked, then a turn toward the next page landed; the manager has not settled yet
- (void)landTurn
{
  [self bakeFirstPage];
  [_machine turnBegan];
  [_machine turnFinishedToward:@"next" completed:YES];
}

#pragma mark - the bake loop

- (void)testStateNamesMatchTheLog
{
  XCTAssertEqualObjects(RNCPageCurlStateName(RNCPageCurlStateIdle), @"idle");
  XCTAssertEqualObjects(RNCPageCurlStateName(RNCPageCurlStateAnimating), @"animating");
  XCTAssertEqualObjects(RNCPageCurlStateName(RNCPageCurlStateBaking), @"baking");
  XCTAssertEqualObjects(RNCPageCurlStateName(RNCPageCurlStateAwaitingSettle), @"awaitingSettle");
  XCTAssertEqualObjects(RNCPageCurlStateName(RNCPageCurlStateAwaitingTapResult), @"awaitingTapResult");
}

- (void)testEnablingWaitsForTheFirstSettle
{
  XCTAssertEqualObjects(Describe([_machine enable]), (@[@"state awaitingSettle (enabled)"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
}

- (void)testASettleStartsABake
{
  [_machine enable];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 1)]), (@[@"state baking (settle)", @"bake page 3 chunk 1"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateBaking);
}

- (void)testAFinishedBakeOpensInput
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:YES]), (@[@"state idle (baked)"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateIdle);
}

- (void)testASettleWhileIdleBakesAgain
{
  [self bakeFirstPage];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(4, 1)]), (@[@"state baking (settle)", @"bake page 4 chunk 1"]));
}

- (void)testASettleDuringABakeIsKeptAndBakedAfter
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(4, 1)]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateBaking);
  XCTAssertEqualObjects(Describe([_machine bakeFinished:YES]), (@[@"bake page 4 chunk 1"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateBaking);
  XCTAssertEqualObjects(Describe([_machine bakeFinished:YES]), (@[@"state idle (baked)"]));
}

- (void)testOnlyTheLatestSettleKeptDuringABakeIsBaked
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine settled:Settle(4, 1)];
  [_machine settled:Settle(5, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:YES]), (@[@"bake page 5 chunk 1"]));
}

- (void)testEveryStateChangeMovesTheSerial
{
  NSUInteger initial = _machine.stateSerial;
  [_machine enable];
  NSUInteger enabled = _machine.stateSerial;
  [_machine settled:Settle(3, 1)];
  NSUInteger baking = _machine.stateSerial;
  [_machine settled:Settle(4, 1)];
  XCTAssertNotEqual(initial, enabled);
  XCTAssertNotEqual(enabled, baking);
  XCTAssertEqual(_machine.stateSerial, baking, @"a kept settle changes no state");
}

#pragma mark - failed bakes

- (void)testAFailedBakeBlanksTheSlotsAndAsksForASettle
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:NO]), (@[@"blank slots", @"state awaitingSettle (bake failed)", @"request settle"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
}

- (void)testThreeFailedBakesInARowGoIdleWithoutAsking
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:NO];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:NO];
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:NO]), (@[@"blank slots", @"state idle (bakes kept failing)"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateIdle);
}

- (void)testASuccessfulBakeResetsTheFailureCount
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:NO];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:NO];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:YES];
  [_machine settled:Settle(4, 1)];
  [_machine bakeFinished:NO];
  [_machine settled:Settle(4, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:NO]), (@[@"blank slots", @"state awaitingSettle (bake failed)", @"request settle"]));
}

- (void)testAKeptSettleIsBakedAfterAFailedBakeWithoutCountingTheFailure
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine settled:Settle(4, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:NO]), (@[@"blank slots", @"bake page 4 chunk 1"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateBaking);
  // two counted failures leave the machine still asking; a counted kept one would have made three
  [_machine bakeFinished:NO];
  [_machine settled:Settle(4, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:NO]), (@[@"blank slots", @"state awaitingSettle (bake failed)", @"request settle"]));
}

#pragma mark - failed settle requests

- (void)testAFailedSettleRequestBlanksTheSlotsAndGoesIdle
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  NSUInteger token = SettleRequestToken([_machine bakeFinished:NO]);
  XCTAssertNotEqual(token, 0);
  XCTAssertEqualObjects(Describe([_machine settleRequestFinished:NO token:token]), (@[@"blank slots", @"state idle (settle request failed)"]));
}

- (void)testASuccessfulSettleRequestChangesNothing
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  NSUInteger token = SettleRequestToken([_machine bakeFinished:NO]);
  XCTAssertEqualObjects(Describe([_machine settleRequestFinished:YES token:token]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
}

- (void)testAFailedSettleRequestFromAnEarlierWaitChangesNothing
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  NSUInteger token = SettleRequestToken([_machine bakeFinished:NO]);
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:YES];
  XCTAssertEqualObjects(Describe([_machine settleRequestFinished:NO token:token]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateIdle);
}

- (void)testAFailedSettleRequestFromAnEarlierWaitForTheSameStateChangesNothing
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  NSUInteger first = SettleRequestToken([_machine bakeFinished:NO]);
  [_machine settled:Settle(3, 1)];
  NSUInteger second = SettleRequestToken([_machine bakeFinished:NO]);
  XCTAssertNotEqual(first, second);
  XCTAssertEqualObjects(Describe([_machine settleRequestFinished:NO token:first]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
}

#pragma mark - turns

- (void)testATurnBeginsOnlyWhenIdle
{
  [_machine enable];
  XCTAssertFalse(_machine.canBeginTurn);
  XCTAssertEqualObjects(Describe([_machine turnBegan]), (@[]));
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:YES];
  XCTAssertTrue(_machine.canBeginTurn);
  XCTAssertEqualObjects(Describe([_machine turnBegan]), (@[@"state animating (turn begins)"]));
  XCTAssertFalse(_machine.canBeginTurn);
}

- (void)testASettleDuringATurnIsKept
{
  [self bakeFirstPage];
  [_machine turnBegan];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(4, 1)]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAnimating);
}

- (void)testACancelledTurnShowsTheCurrentPageAndRests
{
  [self bakeFirstPage];
  [_machine turnBegan];
  XCTAssertEqualObjects(Describe([_machine turnFinishedToward:@"next" completed:NO]), (@[@"show current", @"state idle (turn cancelled)"]));
}

- (void)testACancelledTurnBakesTheKeptSettle
{
  [self bakeFirstPage];
  [_machine turnBegan];
  [_machine settled:Settle(4, 1)];
  XCTAssertEqualObjects(Describe([_machine turnFinishedToward:@"next" completed:NO]),
                        (@[@"show current", @"state baking (settle)", @"bake page 4 chunk 1"]));
}

- (void)testALandedTurnShowsTheLandedPageAndAsksTheManagerToLand
{
  [self bakeFirstPage];
  [_machine turnBegan];
  XCTAssertEqualObjects(Describe([_machine turnFinishedToward:@"next" completed:YES]),
                        (@[@"show landed next", @"state awaitingSettle (turn landed)", @"land next"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
}

- (void)testALandedTurnDropsTheSettleKeptDuringIt
{
  [self bakeFirstPage];
  [_machine turnBegan];
  [_machine settled:Settle(9, 1)];
  [_machine turnFinishedToward:@"next" completed:YES];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(4, 1)]), (@[@"state baking (settle)", @"bake page 4 chunk 1"]));
}

- (void)testATurnFinishedWhileNotAnimatingChangesNothing
{
  [self bakeFirstPage];
  XCTAssertEqualObjects(Describe([_machine turnFinishedToward:@"next" completed:YES]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateIdle);
}

#pragma mark - landing guard

- (void)testASettleForThePageJustLeftIsDroppedAfterALanding
{
  [self landTurn];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 1)]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
  XCTAssertEqualObjects(Describe([_machine settled:Settle(4, 1)]), (@[@"state baking (settle)", @"bake page 4 chunk 1"]));
}

- (void)testASettleForTheSamePageInAnotherChunkBakesAfterALanding
{
  [self landTurn];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 2)]), (@[@"state baking (settle)", @"bake page 3 chunk 2"]));
}

- (void)testUnsettledEndsTheLandingGuard
{
  [self landTurn];
  XCTAssertEqualObjects(Describe([_machine unsettled]), (@[]));
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 1)]), (@[@"state baking (settle)", @"bake page 3 chunk 1"]));
}

- (void)testAFailedLandingEndsTheGuardAndAsksForASettle
{
  [self landTurn];
  XCTAssertEqualObjects(Describe([_machine landingFinished:NO]), (@[@"request settle"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 1)]), (@[@"state baking (settle)", @"bake page 3 chunk 1"]));
}

- (void)testASuccessfulLandingChangesNothing
{
  [self landTurn];
  XCTAssertEqualObjects(Describe([_machine landingFinished:YES]), (@[]));
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 1)]), (@[]), @"the guard still holds");
}

- (void)testTheGuardEndsOnceAnotherPageBakes
{
  [self landTurn];
  [_machine settled:Settle(4, 1)];
  [_machine bakeFinished:YES];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 1)]), (@[@"state baking (settle)", @"bake page 3 chunk 1"]));
}

#pragma mark - taps

- (void)testATapWaitsForItsResult
{
  [self bakeFirstPage];
  XCTAssertEqualObjects(Describe([_machine tapped]), (@[@"state awaitingTapResult (tap)"]));
  XCTAssertFalse(_machine.canBeginTurn);
}

- (void)testATapThatTurnedNoPageOpensInput
{
  [self bakeFirstPage];
  [_machine tapped];
  XCTAssertEqualObjects(Describe([_machine touchEnded]), (@[@"state idle (tap turned no page)"]));
}

- (void)testASettleAfterATapBakes
{
  [self bakeFirstPage];
  [_machine tapped];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(4, 1)]), (@[@"state baking (settle)", @"bake page 4 chunk 1"]));
}

- (void)testUnsettledAfterATapWaitsForTheSettle
{
  [self bakeFirstPage];
  [_machine tapped];
  XCTAssertEqualObjects(Describe([_machine unsettled]), (@[@"state awaitingSettle (unsettled)"]));
}

- (void)testATapWhileBusyChangesNothing
{
  [_machine enable];
  XCTAssertEqualObjects(Describe([_machine tapped]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateAwaitingSettle);
}

- (void)testATouchEndWhileIdleChangesNothing
{
  [self bakeFirstPage];
  XCTAssertEqualObjects(Describe([_machine touchEnded]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateIdle);
}

#pragma mark - unsettled and rebake requests

- (void)testUnsettledWhileIdleWaitsForTheSettle
{
  [self bakeFirstPage];
  XCTAssertEqualObjects(Describe([_machine unsettled]), (@[@"state awaitingSettle (unsettled)"]));
}

- (void)testUnsettledDuringABakeChangesNothing
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine unsettled]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateBaking);
}

- (void)testARebakeRequestWhileIdleWaitsAndAsks
{
  [self bakeFirstPage];
  XCTAssertEqualObjects(Describe([_machine rebakeRequested:@"resize"]), (@[@"state awaitingSettle (resize)", @"request settle"]));
}

- (void)testARebakeRequestWhileWaitingOnATapWaitsAndAsks
{
  [self bakeFirstPage];
  [_machine tapped];
  XCTAssertEqualObjects(Describe([_machine rebakeRequested:@"resize"]), (@[@"state awaitingSettle (resize)", @"request settle"]));
}

- (void)testARebakeRequestDuringABakeOnlyAsks
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine rebakeRequested:@"resize"]), (@[@"request settle"]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateBaking);
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:YES]), (@[@"bake page 3 chunk 1"]), @"the settle that came back is kept");
}

- (void)testAFailedRebakeRequestWhileIdleOpensInputAgain
{
  [self bakeFirstPage];
  NSUInteger token = SettleRequestToken([_machine rebakeRequested:@"resize"]);
  XCTAssertEqualObjects(Describe([_machine settleRequestFinished:NO token:token]), (@[@"blank slots", @"state idle (settle request failed)"]));
}

#pragma mark - teardown

- (void)testTeardownGoesIdleWithNothingKeptAndMovesTheSerial
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine settled:Settle(4, 1)];
  NSUInteger before = _machine.stateSerial;
  [_machine teardown];
  XCTAssertEqual(_machine.state, RNCPageCurlStateIdle);
  XCTAssertNotEqual(_machine.stateSerial, before);
  XCTAssertEqualObjects(_machine.summary, @"idle");
}

- (void)testTeardownClearsTheLandingGuard
{
  [self landTurn];
  [_machine teardown];
  [_machine enable];
  XCTAssertEqualObjects(Describe([_machine settled:Settle(3, 1)]), (@[@"state baking (settle)", @"bake page 3 chunk 1"]));
}

- (void)testTeardownClearsTheFailureCount
{
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:NO];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:NO];
  [_machine teardown];
  [_machine enable];
  [_machine settled:Settle(3, 1)];
  [_machine bakeFinished:NO];
  [_machine settled:Settle(3, 1)];
  XCTAssertEqualObjects(Describe([_machine bakeFinished:NO]), (@[@"blank slots", @"state awaitingSettle (bake failed)", @"request settle"]));
}

- (void)testResultsAfterATeardownChangeNothing
{
  [self landTurn];
  [_machine settled:Settle(4, 1)];
  NSUInteger token = SettleRequestToken([_machine rebakeRequested:@"resize"]);
  [_machine teardown];
  NSUInteger serial = _machine.stateSerial;
  XCTAssertEqualObjects(Describe([_machine bakeFinished:YES]), (@[]));
  XCTAssertEqualObjects(Describe([_machine bakeFinished:NO]), (@[]));
  XCTAssertEqualObjects(Describe([_machine landingFinished:NO]), (@[]));
  XCTAssertEqualObjects(Describe([_machine settleRequestFinished:NO token:token]), (@[]));
  XCTAssertEqual(_machine.state, RNCPageCurlStateIdle);
  XCTAssertEqual(_machine.stateSerial, serial);
}

#pragma mark - every ordering

typedef NSArray<RNCPageCurlEffect *> *(^RNCPageCurlEvent)(RNCPageCurlStateMachine *machine, NSUInteger lastToken);

// every event the controller can report, as a block the sweep applies to a machine
- (NSDictionary<NSString *, RNCPageCurlEvent> *)events
{
  return @{
    @"settled 3": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m settled:Settle(3, 1)]; },
    @"settled 4": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m settled:Settle(4, 1)]; },
    @"unsettled": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m unsettled]; },
    @"touchEnded": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m touchEnded]; },
    @"tapped": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m tapped]; },
    @"turnBegan": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m turnBegan]; },
    @"turn landed": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m turnFinishedToward:@"next" completed:YES]; },
    @"turn cancelled": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m turnFinishedToward:@"next" completed:NO]; },
    @"bake ok": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m bakeFinished:YES]; },
    @"bake failed": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m bakeFinished:NO]; },
    @"landing ok": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m landingFinished:YES]; },
    @"landing failed": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m landingFinished:NO]; },
    @"settle request failed": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m settleRequestFinished:NO token:token]; },
    @"rebake": ^(RNCPageCurlStateMachine *m, NSUInteger token) { return [m rebakeRequested:@"resize"]; },
  };
}

// replays `sequence` on a fresh enabled machine and checks the invariants after every step
- (void)checkSequence:(NSArray<NSString *> *)sequence events:(NSDictionary<NSString *, RNCPageCurlEvent> *)events
{
  RNCPageCurlStateMachine *machine = [RNCPageCurlStateMachine new];
  [machine enable];
  NSUInteger bakesOutstanding = 0;
  NSUInteger lastToken = 0;
  NSUInteger lastSerial = machine.stateSerial;
  BOOL settleExpected = YES;
  NSString *trail = @"enable";
  for (NSString *name in sequence) {
    trail = [trail stringByAppendingFormat:@" > %@", name];
    BOOL wasBaking = machine.state == RNCPageCurlStateBaking;
    NSArray<RNCPageCurlEffect *> *effects = events[name](machine, lastToken);

    if ([name hasPrefix:@"bake "] && wasBaking) {
      bakesOutstanding -= 1;
    }
    NSUInteger bakesStarted = 0;
    for (RNCPageCurlEffect *effect in effects) {
      if (effect.kind == RNCPageCurlEffectBake) {
        bakesStarted += 1;
      }
      if (effect.kind == RNCPageCurlEffectRequestSettle) {
        lastToken = effect.token;
        settleExpected = YES;
      }
      if (effect.kind == RNCPageCurlEffectLand) {
        settleExpected = YES;
      }
    }
    bakesOutstanding += bakesStarted;
    if ([name isEqualToString:@"unsettled"]) {
      settleExpected = YES;
    }
    if ([name hasPrefix:@"settled"] && (bakesStarted > 0 || machine.state == RNCPageCurlStateBaking || machine.state == RNCPageCurlStateAnimating)) {
      settleExpected = NO;
    }

    XCTAssertLessThanOrEqual(bakesStarted, 1, @"%@: one bake per step", trail);
    XCTAssertLessThanOrEqual(bakesOutstanding, 1, @"%@: at most one bake outstanding", trail);
    XCTAssertEqual(machine.state == RNCPageCurlStateBaking, bakesOutstanding == 1, @"%@: baking exactly while a bake is outstanding", trail);
    if (bakesStarted > 0) {
      XCTAssertEqual(machine.state, RNCPageCurlStateBaking, @"%@: a bake starts only on entering baking", trail);
    }
    XCTAssertEqual(machine.canBeginTurn, machine.state == RNCPageCurlStateIdle, @"%@: input is blocked exactly when not idle", trail);
    if (machine.state == RNCPageCurlStateAwaitingSettle) {
      XCTAssertTrue(settleExpected, @"%@: waiting for a settle nothing will send", trail);
    }
    BOOL stateChanged = Contains(effects, RNCPageCurlEffectEnterState);
    XCTAssertEqual(machine.stateSerial != lastSerial, stateChanged, @"%@: the serial moves exactly on a state change", trail);
    XCTAssertGreaterThanOrEqual(machine.stateSerial, lastSerial, @"%@: the serial never goes back", trail);
    lastSerial = machine.stateSerial;
  }
}

- (void)testEveryOrderingKeepsTheInvariants
{
  NSDictionary<NSString *, RNCPageCurlEvent> *events = [self events];
  NSArray<NSString *> *names = [events.allKeys sortedArrayUsingSelector:@selector(compare:)];
  const NSUInteger depth = 5;
  NSUInteger count = 1;
  for (NSUInteger i = 0; i < depth; i++) {
    count *= names.count;
  }
  for (NSUInteger index = 0; index < count; index++) {
    NSMutableArray<NSString *> *sequence = [NSMutableArray arrayWithCapacity:depth];
    NSUInteger rest = index;
    for (NSUInteger i = 0; i < depth; i++) {
      [sequence addObject:names[rest % names.count]];
      rest /= names.count;
    }
    [self checkSequence:sequence events:events];
  }
}

@end
