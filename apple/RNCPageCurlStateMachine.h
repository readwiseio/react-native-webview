#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// the only state the controller keeps about the bake loop; input reaches the webview only when idle
typedef NS_ENUM(NSInteger, RNCPageCurlState) {
  RNCPageCurlStateIdle,
  // a finger is turning a sheet, or the release animation is playing; the DOM does not move
  RNCPageCurlStateAnimating,
  // the slots are being snapshotted; runs to completion, a settle that arrives meanwhile is kept for after
  RNCPageCurlStateBaking,
  // the manager is moving the page (a tap, a jump, or a landed curl's page turn); its settle starts the bake
  RNCPageCurlStateAwaitingSettle,
  // a tap reached the webview; the manager answers with a settle (page turned) or touchEnd (nothing turned)
  RNCPageCurlStateAwaitingTapResult,
};

FOUNDATION_EXPORT NSString *RNCPageCurlStateName(RNCPageCurlState state);

typedef NS_ENUM(NSInteger, RNCPageCurlEffectKind) {
  // the state changed; `state` and `reason`
  RNCPageCurlEffectEnterState,
  // snapshot the slots around the page `settle` names, then report bakeFinished:; with a `direction`, only
  // the slot beyond the page in that direction, since the turn there already rotated the other two
  RNCPageCurlEffectBake,
  // the slots describe another page: no direction curls until the next bake
  RNCPageCurlEffectBlankSlots,
  // the turn toward `direction` landed: the cover shows that page
  RNCPageCurlEffectShowLandedPage,
  // the turn was cancelled: the cover shows the page it started on
  RNCPageCurlEffectShowCurrentPage,
  // ask the manager to turn the page toward `direction`, then report landingFinished:
  RNCPageCurlEffectLand,
  // ask the manager to settle again, then report settleRequestFinished:token: with `token`
  RNCPageCurlEffectRequestSettle,
  // nothing to do; `reason` is a line for the log
  RNCPageCurlEffectNote,
};

@interface RNCPageCurlEffect : NSObject
@property (nonatomic, readonly) RNCPageCurlEffectKind kind;
@property (nonatomic, readonly) RNCPageCurlState state;
@property (nonatomic, readonly, copy, nullable) NSString *reason;
@property (nonatomic, readonly, copy, nullable) NSDictionary *settle;
@property (nonatomic, readonly, copy, nullable) NSString *direction;
@property (nonatomic, readonly) NSUInteger token;
@end

/**
 * The page curl's bake loop as events in and effects out, with no views and no webview.
 * The controller reports what happened and carries out the effects in order.
 */
@interface RNCPageCurlStateMachine : NSObject

@property (nonatomic, readonly) RNCPageCurlState state;
// changes on every state change and on teardown
@property (nonatomic, readonly) NSUInteger stateSerial;
@property (nonatomic, readonly) BOOL canBeginTurn;
// state and what is being held, for the log
@property (nonatomic, readonly) NSString *summary;

- (NSArray<RNCPageCurlEffect *> *)enable;
- (void)teardown;

// messages from the manager
- (NSArray<RNCPageCurlEffect *> *)settled:(NSDictionary *)settle;
- (NSArray<RNCPageCurlEffect *> *)unsettled;
- (NSArray<RNCPageCurlEffect *> *)touchEnded;

// the finger
- (NSArray<RNCPageCurlEffect *> *)tapped;
- (NSArray<RNCPageCurlEffect *> *)turnBegan;
- (NSArray<RNCPageCurlEffect *> *)turnFinishedToward:(NSString *)direction completed:(BOOL)completed;

// results of effects
- (NSArray<RNCPageCurlEffect *> *)bakeFinished:(BOOL)ok;
- (NSArray<RNCPageCurlEffect *> *)landingFinished:(BOOL)ok;
- (NSArray<RNCPageCurlEffect *> *)settleRequestFinished:(BOOL)ok token:(NSUInteger)token;

// the bakes no longer match the page (resize, spine change)
- (NSArray<RNCPageCurlEffect *> *)rebakeRequested:(NSString *)reason;

@end

NS_ASSUME_NONNULL_END
