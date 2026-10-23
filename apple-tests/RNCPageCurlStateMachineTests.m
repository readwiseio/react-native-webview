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

@end
