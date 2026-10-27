#import "RNCPageCurlStateMachine.h"

static const NSUInteger RNCPageCurlMaxFailedBakes = 3;

NSString *RNCPageCurlStateName(RNCPageCurlState state)
{
  switch (state) {
    case RNCPageCurlStateIdle: return @"idle";
    case RNCPageCurlStateAnimating: return @"animating";
    case RNCPageCurlStateBaking: return @"baking";
    case RNCPageCurlStateAwaitingSettle: return @"awaitingSettle";
    case RNCPageCurlStateAwaitingTapResult: return @"awaitingTapResult";
  }
  return @"?";
}

@interface RNCPageCurlEffect ()
@property (nonatomic, readwrite) RNCPageCurlEffectKind kind;
@property (nonatomic, readwrite) RNCPageCurlState state;
@property (nonatomic, readwrite, copy, nullable) NSString *reason;
@property (nonatomic, readwrite, copy, nullable) NSDictionary *settle;
@property (nonatomic, readwrite, copy, nullable) NSString *direction;
@property (nonatomic, readwrite) NSUInteger token;
@end

@implementation RNCPageCurlEffect

+ (instancetype)effectOfKind:(RNCPageCurlEffectKind)kind
{
  RNCPageCurlEffect *effect = [self new];
  effect.kind = kind;
  return effect;
}

- (NSString *)description
{
  switch (self.kind) {
    case RNCPageCurlEffectEnterState: return [NSString stringWithFormat:@"enter %@ (%@)", RNCPageCurlStateName(self.state), self.reason];
    case RNCPageCurlEffectBake: return [NSString stringWithFormat:@"bake page %@ chunk %@", self.settle[@"page"], self.settle[@"chunkIndex"]];
    case RNCPageCurlEffectBlankSlots: return @"blank slots";
    case RNCPageCurlEffectShowLandedPage: return [NSString stringWithFormat:@"show landed %@", self.direction];
    case RNCPageCurlEffectShowCurrentPage: return @"show current page";
    case RNCPageCurlEffectLand: return [NSString stringWithFormat:@"land %@", self.direction];
    case RNCPageCurlEffectRequestSettle: return [NSString stringWithFormat:@"request settle #%lu", (unsigned long)self.token];
    case RNCPageCurlEffectNote: return [NSString stringWithFormat:@"note: %@", self.reason];
  }
  return @"?";
}

@end

@implementation RNCPageCurlStateMachine {
  // a settle that arrived while a bake or a turn was running; baked once that ends
  NSDictionary *_keptSettle;
  // the settle the slots were last baked from
  NSDictionary *_bakedSettle;
  // after a landed turn, a settle naming the page just left is from before the landing
  BOOL _awaitingLanding;
  NSUInteger _failedBakes;
  NSUInteger _settleRequestToken;
  NSUInteger _settleRequestSerial;
}

- (instancetype)init
{
  if (self = [super init]) {
    _state = RNCPageCurlStateIdle;
  }
  return self;
}

- (BOOL)canBeginTurn
{
  return _state == RNCPageCurlStateIdle;
}

- (NSString *)summary
{
  NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:RNCPageCurlStateName(_state)];
  if (_keptSettle != nil) {
    [parts addObject:[NSString stringWithFormat:@"kept page %@ chunk %@", _keptSettle[@"page"], _keptSettle[@"chunkIndex"]]];
  }
  if (_awaitingLanding) {
    [parts addObject:@"awaiting landing"];
  }
  if (_failedBakes > 0) {
    [parts addObject:[NSString stringWithFormat:@"%lu failed bakes", (unsigned long)_failedBakes]];
  }
  return [parts componentsJoinedByString:@", "];
}

#pragma mark - effects

- (RNCPageCurlEffect *)enter:(RNCPageCurlState)state reason:(NSString *)reason
{
  RNCPageCurlEffect *effect = [RNCPageCurlEffect effectOfKind:RNCPageCurlEffectEnterState];
  effect.state = state;
  effect.reason = reason;
  return effect;
}

- (RNCPageCurlEffect *)note:(NSString *)reason
{
  RNCPageCurlEffect *effect = [RNCPageCurlEffect effectOfKind:RNCPageCurlEffectNote];
  effect.reason = reason;
  return effect;
}

- (RNCPageCurlEffect *)directed:(RNCPageCurlEffectKind)kind toward:(NSString *)direction
{
  RNCPageCurlEffect *effect = [RNCPageCurlEffect effectOfKind:kind];
  effect.direction = direction;
  return effect;
}

// the state changes once per call at most, so a list holds at most one enter effect
- (void)setState:(RNCPageCurlState)state reason:(NSString *)reason into:(NSMutableArray<RNCPageCurlEffect *> *)effects
{
  if (state == _state) {
    return;
  }
  _state = state;
  _stateSerial += 1;
  [effects addObject:[self enter:state reason:reason]];
}

- (void)bake:(NSDictionary *)settle into:(NSMutableArray<RNCPageCurlEffect *> *)effects
{
  _keptSettle = nil;
  _awaitingLanding = NO;
  _bakedSettle = settle;
  [self setState:RNCPageCurlStateBaking reason:@"settle" into:effects];
  RNCPageCurlEffect *effect = [RNCPageCurlEffect effectOfKind:RNCPageCurlEffectBake];
  effect.settle = settle;
  [effects addObject:effect];
}

// the kept settle starts the next bake under the same cover; with none the machine rests
- (void)bakeKeptOrIdle:(NSString *)reason into:(NSMutableArray<RNCPageCurlEffect *> *)effects
{
  if (_keptSettle != nil) {
    [self bake:_keptSettle into:effects];
    return;
  }
  [self setState:RNCPageCurlStateIdle reason:reason into:effects];
}

- (void)requestSettleInto:(NSMutableArray<RNCPageCurlEffect *> *)effects
{
  _settleRequestToken += 1;
  _settleRequestSerial = _stateSerial;
  RNCPageCurlEffect *effect = [RNCPageCurlEffect effectOfKind:RNCPageCurlEffectRequestSettle];
  effect.token = _settleRequestToken;
  [effects addObject:effect];
}

// the manager is about to move the page: a machine resting on it waits for the settle
- (void)awaitSettleIfResting:(NSString *)reason into:(NSMutableArray<RNCPageCurlEffect *> *)effects
{
  if (_state == RNCPageCurlStateIdle || _state == RNCPageCurlStateAwaitingTapResult) {
    [self setState:RNCPageCurlStateAwaitingSettle reason:reason into:effects];
  }
}

#pragma mark - lifecycle

- (NSArray<RNCPageCurlEffect *> *)enable
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  _keptSettle = nil;
  _bakedSettle = nil;
  _awaitingLanding = NO;
  _failedBakes = 0;
  // nothing is baked yet; the manager's first settle starts the first bake
  [self setState:RNCPageCurlStateAwaitingSettle reason:@"enabled" into:effects];
  return effects;
}

- (void)teardown
{
  _stateSerial += 1;
  _state = RNCPageCurlStateIdle;
  _keptSettle = nil;
  _bakedSettle = nil;
  _awaitingLanding = NO;
  _failedBakes = 0;
}

#pragma mark - messages from the manager

- (NSArray<RNCPageCurlEffect *> *)settled:(NSDictionary *)settle
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  if (_state == RNCPageCurlStateBaking || _state == RNCPageCurlStateAnimating) {
    _keptSettle = settle;
    [effects addObject:[self note:[NSString stringWithFormat:@"settle kept until the %@ ends", RNCPageCurlStateName(_state)]]];
    return effects;
  }
  // posted during the turn, delivered after it landed: it names the page the reader just left
  if (_awaitingLanding && [self settle:settle namesSamePageAs:_bakedSettle]) {
    [effects addObject:[self note:@"settle for the page just left; dropped"]];
    return effects;
  }
  [self bake:settle into:effects];
  return effects;
}

- (NSArray<RNCPageCurlEffect *> *)unsettled
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  // the manager posts this before it moves, so every settle after it is from after the landing
  _awaitingLanding = NO;
  [self awaitSettleIfResting:@"unsettled" into:effects];
  return effects;
}

- (NSArray<RNCPageCurlEffect *> *)touchEnded
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  if (_state == RNCPageCurlStateAwaitingTapResult) {
    [self setState:RNCPageCurlStateIdle reason:@"tap turned no page" into:effects];
  }
  return effects;
}

#pragma mark - the finger

- (NSArray<RNCPageCurlEffect *> *)tapped
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  if (_state == RNCPageCurlStateIdle) {
    [self setState:RNCPageCurlStateAwaitingTapResult reason:@"tap" into:effects];
  }
  return effects;
}

- (NSArray<RNCPageCurlEffect *> *)turnBegan
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  if (_state == RNCPageCurlStateIdle) {
    [self setState:RNCPageCurlStateAnimating reason:@"turn begins" into:effects];
  }
  return effects;
}

- (NSArray<RNCPageCurlEffect *> *)turnFinishedToward:(NSString *)direction completed:(BOOL)completed
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  if (_state != RNCPageCurlStateAnimating) {
    [effects addObject:[self note:@"turn finished while not animating; ignored"]];
    return effects;
  }
  if (!completed) {
    // the three bakes are still valid
    [effects addObject:[RNCPageCurlEffect effectOfKind:RNCPageCurlEffectShowCurrentPage]];
    [self bakeKeptOrIdle:@"turn cancelled" into:effects];
    return effects;
  }
  // the cover shows the landed page; the manager turns to it and its settle bakes every slot again
  [effects addObject:[self directed:RNCPageCurlEffectShowLandedPage toward:direction]];
  // a settle from during the turn describes the page just left; the landing produces a fresh one
  _keptSettle = nil;
  _awaitingLanding = YES;
  [self setState:RNCPageCurlStateAwaitingSettle reason:@"turn landed" into:effects];
  [effects addObject:[self directed:RNCPageCurlEffectLand toward:direction]];
  return effects;
}

#pragma mark - results of effects

- (NSArray<RNCPageCurlEffect *> *)bakeFinished:(BOOL)ok
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  if (_state != RNCPageCurlStateBaking) {
    [effects addObject:[self note:@"bake finished while not baking; ignored"]];
    return effects;
  }
  if (ok) {
    _failedBakes = 0;
    [self bakeKeptOrIdle:@"baked" into:effects];
    return effects;
  }
  // the slots describe another page now
  [effects addObject:[RNCPageCurlEffect effectOfKind:RNCPageCurlEffectBlankSlots]];
  if (_keptSettle != nil) {
    [self bake:_keptSettle into:effects];
    return effects;
  }
  _failedBakes += 1;
  if (_failedBakes >= RNCPageCurlMaxFailedBakes) {
    // taps still turn pages; the next settle the manager sends on its own bakes again
    [self setState:RNCPageCurlStateIdle reason:@"bakes kept failing" into:effects];
    return effects;
  }
  [self setState:RNCPageCurlStateAwaitingSettle reason:@"bake failed" into:effects];
  [self requestSettleInto:effects];
  return effects;
}

- (NSArray<RNCPageCurlEffect *> *)landingFinished:(BOOL)ok
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  // a landing that already produced its settle, or was torn down, has nothing left to repair
  if (ok || !_awaitingLanding) {
    return effects;
  }
  // the webview never moved, so the settle it sends names the page the turn started on
  _awaitingLanding = NO;
  [self awaitSettleIfResting:@"landing failed" into:effects];
  [self requestSettleInto:effects];
  return effects;
}

- (NSArray<RNCPageCurlEffect *> *)settleRequestFinished:(BOOL)ok token:(NSUInteger)token
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  BOOL sameWait = _state == RNCPageCurlStateAwaitingSettle && token == _settleRequestToken && _stateSerial == _settleRequestSerial;
  if (ok || !sameWait) {
    return effects;
  }
  // no settle is coming: open input with nothing to curl onto until the manager settles on its own
  [effects addObject:[RNCPageCurlEffect effectOfKind:RNCPageCurlEffectBlankSlots]];
  [self setState:RNCPageCurlStateIdle reason:@"settle request failed" into:effects];
  return effects;
}

- (NSArray<RNCPageCurlEffect *> *)rebakeRequested:(NSString *)reason
{
  NSMutableArray<RNCPageCurlEffect *> *effects = [NSMutableArray array];
  // a busy machine needs nothing more: the settle that comes back is kept and baked when it frees
  [self awaitSettleIfResting:reason into:effects];
  [self requestSettleInto:effects];
  return effects;
}

#pragma mark - helpers

- (BOOL)settle:(NSDictionary *)settle namesSamePageAs:(NSDictionary *)other
{
  return other != nil &&
      [settle[@"page"] integerValue] == [other[@"page"] integerValue] &&
      [settle[@"chunkIndex"] integerValue] == [other[@"chunkIndex"] integerValue];
}

@end
