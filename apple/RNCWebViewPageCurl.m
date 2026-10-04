#import "RNCWebViewPageCurl.h"
#import "RNCPageCurlRenderer.h"
#import <UIKit/UIGestureRecognizerSubclass.h>

BOOL RNCPageCurlLoggingEnabled = NO;

static NSString *const RNCPageCurlSlotCurrent = @"current";
static NSString *const RNCPageCurlSlotPrevious = @"previous";
static NSString *const RNCPageCurlSlotNext = @"next";
static const NSUInteger RNCPageCurlMaxFailedBakes = 3;

// defaults for the tuning JSON; the Bookwise side documents each knob
static NSDictionary<NSString *, NSNumber *> *RNCPageCurlTuningDefaults(void)
{
  return @{
    @"radiusFraction": @0.12,
    @"radiusMax": @90,
    @"bendInDistance": @30,
    @"settleGain": @2,
    @"tiltSoftness": @120,
    @"castWidthFloor": @0.5,
    @"castWidthPerRadius": @0.9,
    @"castStrengthFloor": @0.6,
    @"castSoftness": @0.35,
    @"aheadNear": @0.8,
    @"aheadFar": @2.4,
    @"bendDarken": @0.55,
    @"bendDarkenIn": @80,
    @"crestPosition": @0.62,
    @"crestWidth": @0.13,
    @"riseScale": @0.35,
    @"aheadStrength": @1.0,
    @"tightFade": @0.7,
    @"backShowThrough": @0.15,
    @"completeDistance": @40,
    @"flickVelocity": @400,
    @"durationBase": @0.18,
    @"durationPerRemaining": @0.32,
    @"speedMin": @0.45,
    @"speedMax": @1.3,
  };
}

typedef void (^RNCPageCurlStep)(void (^done)(BOOL ok));

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

static NSString *RNCPageCurlStateName(RNCPageCurlState state)
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

// the paper faded toward the opposite extreme so it reads as the reverse side in both themes
static UIColor *RNCPageCurlFadedPaper(UIColor *paper)
{
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [paper getRed:&r green:&g blue:&b alpha:&a];
  CGFloat luma = 0.299 * r + 0.587 * g + 0.114 * b;
  CGFloat toward = luma < 0.5 ? 1.0 : 0.0;
  CGFloat amount = 0.12;
  return [UIColor colorWithRed:r + (toward - r) * amount green:g + (toward - g) * amount blue:b + (toward - b) * amount alpha:1];
}

static CGFloat RNCPageCurlEaseOut(CGFloat t)
{
  CGFloat inv = 1 - t;
  return 1 - inv * inv * inv;
}

// Never recognizes; only reports raw touch begin/end so a tap can be told apart from a drag
// and a still hold can hand the touch back to WebKit's selection recognizers.
@interface RNCPageCurlTouchObserver : UIGestureRecognizer
@property (nonatomic, copy) void (^onTouchesBegan)(void);
@property (nonatomic, copy) void (^onTouchesEnded)(void);
@property (nonatomic, copy) void (^onHeldStill)(void);
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) BOOL moved;
@property (nonatomic, assign) NSUInteger touchSequence;
// the first finger down; later fingers are ignored until it lifts
@property (nonatomic, weak) UITouch *touch;
@end

@implementation RNCPageCurlTouchObserver

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesBegan:touches withEvent:event];
  if (self.touch != nil) {
    return;
  }
  self.touch = touches.anyObject;
  self.startPoint = [self.touch locationInView:self.view];
  self.startTime = CACurrentMediaTime();
  self.moved = NO;
  self.touchSequence += 1;
  NSUInteger sequence = self.touchSequence;
  __weak __typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf != nil && strongSelf.touchSequence == sequence && !strongSelf.moved &&
        strongSelf.state == UIGestureRecognizerStatePossible && strongSelf.onHeldStill) {
      strongSelf.onHeldStill();
    }
  });
  if (self.onTouchesBegan) {
    self.onTouchesBegan();
  }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesMoved:touches withEvent:event];
  UITouch *touch = self.touch;
  if (touch == nil || ![touches containsObject:touch]) {
    return;
  }
  CGPoint point = [touch locationInView:self.view];
  if (fabs(point.x - self.startPoint.x) > 8 || fabs(point.y - self.startPoint.y) > 8) {
    self.moved = YES;
  }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesEnded:touches withEvent:event];
  [self finishTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesCancelled:touches withEvent:event];
  [self finishTouches:touches];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches
{
  UITouch *touch = self.touch;
  if (touch == nil || ![touches containsObject:touch]) {
    return;
  }
  self.touch = nil;
  if (self.onTouchesEnded) {
    self.onTouchesEnded();
  }
  self.state = UIGestureRecognizerStateFailed;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer
{
  return NO;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer
{
  return NO;
}

@end

@interface RNCPageCurlSlot : NSObject
@property (nonatomic, strong, nullable) id<MTLTexture> texture;
// NO at the start or end of the book; a slot with a page but no texture curls onto blank paper
@property (nonatomic, assign) BOOL hasPage;
@end

@implementation RNCPageCurlSlot
@end

@interface RNCWebViewPageCurl () <UIGestureRecognizerDelegate>
@end

@implementation RNCWebViewPageCurl {
  __weak UIView *_hostView;
  __weak WKWebView *_webView;
  RNCPageCurlRenderer *_renderer;
  // sits above the renderer and swallows every touch while the controller is not idle; the curl pan
  // and touch observer live on the host, so they still see the finger through it
  UIView *_inputBlocker;
  NSMutableDictionary<NSString *, RNCPageCurlSlot *> *_slots;
  UIPanGestureRecognizer *_pan;
  RNCPageCurlTouchObserver *_touchObserver;
  UIColor *_adoptedPaper;
  NSDictionary<NSString *, NSNumber *> *_tuningValues;
  BOOL _enabled;
  BOOL _spread;
  BOOL _edgeEmitted;
  RNCPageCurlState _state;
  // UIKit hit-tests once, at touch-down; only a touch it delivered inside the webview is one the
  // manager saw and will answer
  BOOL _touchReachedWebView;
  // a bake step still in flight from a torn-down controller stops; setSpine tears down and re-enables,
  // which _enabled alone cannot tell apart
  NSUInteger _teardownCount;
  // bumped on every state change and on teardown; the settle watchdog checks it has not moved
  NSUInteger _stateSerial;
  // the turn just landed and the manager was asked to move; a settle for the page it left is stale
  BOOL _awaitingLanding;
  // bakes that failed back to back; at the cap the controller stops asking for another
  NSUInteger _failedBakes;
  // the latest settle that arrived while a bake or turn was running; applied once the controller is free
  NSDictionary *_pendingSettle;
  // the page the webview rests on; pages count from 0 inside the chunk
  NSInteger _page;
  NSInteger _lastPage;
  NSInteger _chunkIndex;
  BOOL _isLastChunk;
  CGSize _lastSize;
  // the turn in flight, in sheet-local coordinates where the sheet curls from its right edge
  NSString *_turnDirection;
  CGRect _turnSheetRect;
  BOOL _turnMirrored;
  // the grabbed point on the outer edge, the folded-over point that tracks the finger, and where it sits at rest
  CGPoint _turnStart;
  CGPoint _turnFinger;
  CGPoint _turnRest;
  // the touch-down; the finger is tracked relative to it, since the grab point is not under it
  CGPoint _turnTouchDown;
  // how far the finger has moved in the turn's direction since touch-down
  CGFloat _turnDrag;
  CGFloat _turnRadiusMax;
  // 0 flat, 1 fully folded over
  CGFloat _turnFold;
  // a single-sheet turn back starts folded over and flattens out
  BOOL _turnReversed;
  // this pan asked for a direction with no page; stop asking until it ends
  BOOL _turnDeclined;
  CADisplayLink *_animation;
  CFTimeInterval _animationStart;
  CFTimeInterval _animationDuration;
  CGPoint _animationFrom;
  CGPoint _animationTo;
  BOOL _animationCompletes;
}

- (instancetype)initWithHostView:(UIView *)hostView webView:(WKWebView *)webView
{
  if ((self = [super init])) {
    _hostView = hostView;
    _webView = webView;
    _slots = [NSMutableDictionary dictionary];
    for (NSString *slot in @[RNCPageCurlSlotPrevious, RNCPageCurlSlotCurrent, RNCPageCurlSlotNext]) {
      _slots[slot] = [RNCPageCurlSlot new];
      _slots[slot].hasPage = YES;
    }
  }
  return self;
}

- (void)dealloc
{
  [self teardown];
}

#pragma mark - colors

- (void)setPaperColor:(UIColor *)paperColor
{
  _paperColor = paperColor;
  [self applyColors];
}

- (void)setBackColor:(UIColor *)backColor
{
  _backColor = backColor;
  [self applyColors];
}

- (void)setShadowColor:(UIColor *)shadowColor
{
  _shadowColor = shadowColor;
  [self applyColors];
}

- (void)setShadowOpacity:(NSNumber *)shadowOpacity
{
  _shadowOpacity = shadowOpacity;
  [self applyColors];
}

- (void)setHighlightColor:(UIColor *)highlightColor
{
  _highlightColor = highlightColor;
  [self applyColors];
}

- (void)setHighlightOpacity:(NSNumber *)highlightOpacity
{
  _highlightOpacity = highlightOpacity;
  [self applyColors];
}

- (void)setTuning:(NSString *)tuning
{
  _tuning = [tuning copy];
  NSDictionary *parsed = nil;
  if (tuning.length > 0) {
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:[tuning dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
    if ([object isKindOfClass:[NSDictionary class]]) {
      parsed = object;
    } else {
      RNCPageCurlLog(@"[page-curl] tuning ignored: not a JSON object (%@)", error);
    }
  }
  _tuningValues = parsed;
  [self applyTuning];
}

- (double)tune:(NSString *)key
{
  NSNumber *value = _tuningValues[key];
  if (![value isKindOfClass:[NSNumber class]]) {
    value = RNCPageCurlTuningDefaults()[key];
  }
  return value.doubleValue;
}

- (void)applyTuning
{
  if (_renderer == nil) {
    return;
  }
  RNCPageCurlShading shading;
  shading.castWidthFloor = (float)[self tune:@"castWidthFloor"];
  shading.castWidthPerRadius = (float)[self tune:@"castWidthPerRadius"];
  shading.castStrengthFloor = (float)[self tune:@"castStrengthFloor"];
  shading.castSoftness = (float)[self tune:@"castSoftness"];
  shading.aheadNear = (float)[self tune:@"aheadNear"];
  shading.aheadFar = (float)[self tune:@"aheadFar"];
  shading.aheadStrength = (float)[self tune:@"aheadStrength"];
  shading.bendDarken = (float)[self tune:@"bendDarken"];
  shading.crestPosition = (float)[self tune:@"crestPosition"];
  shading.crestWidth = (float)[self tune:@"crestWidth"];
  shading.riseScale = (float)[self tune:@"riseScale"];
  shading.tightFade = (float)[self tune:@"tightFade"];
  shading.backShowThrough = (float)[self tune:@"backShowThrough"];
  _renderer.shading = shading;
  NSMutableString *summary = [NSMutableString string];
  for (NSString *key in [RNCPageCurlTuningDefaults().allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [summary appendFormat:@" %@=%g", key, [self tune:key]];
  }
  for (NSString *key in _tuningValues) {
    if (RNCPageCurlTuningDefaults()[key] == nil) {
      [summary appendFormat:@" (unknown %@)", key];
    }
  }
  RNCPageCurlLog(@"[page-curl] tuning:%@", summary);
  if (!_renderer.hidden) {
    [_renderer setNeedsDisplay];
  }
}

- (void)applyColors
{
  if (_renderer == nil) {
    return;
  }
  UIColor *paper = _paperColor ?: _adoptedPaper ?: [UIColor whiteColor];
  _renderer.paperColor = paper;
  _renderer.backColor = _backColor ?: RNCPageCurlFadedPaper(paper);
  _renderer.shadowColor = _shadowColor ?: [UIColor blackColor];
  _renderer.shadowOpacity = _shadowOpacity != nil ? _shadowOpacity.doubleValue : 0.35;
  _renderer.highlightColor = _highlightColor ?: [UIColor whiteColor];
  _renderer.highlightOpacity = _highlightOpacity != nil ? _highlightOpacity.doubleValue : 0.2;
  RNCPageCurlLog(@"[page-curl] colors paper=%@ back=%@ shadow=%@@%.2f highlight=%@@%.2f", _renderer.paperColor, _renderer.backColor,
        _renderer.shadowColor, _renderer.shadowOpacity, _renderer.highlightColor, _renderer.highlightOpacity);
  if (!_renderer.hidden) {
    [_renderer setNeedsDisplay];
  }
}

- (void)adoptPaperColorFrom:(UIImage *)image
{
  CGImageRef cg = image.CGImage;
  if (cg == nil) {
    return;
  }
  unsigned char pixel[4] = {255, 255, 255, 255};
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  if (context != nil) {
    // top-left corner is page margin in every layout we ship
    CGImageRef corner = CGImageCreateWithImageInRect(cg, CGRectMake(2, 2, 1, 1));
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), corner);
    CGImageRelease(corner);
    CGContextRelease(context);
  }
  CGColorSpaceRelease(colorSpace);
  _adoptedPaper = [UIColor colorWithRed:pixel[0] / 255.0 green:pixel[1] / 255.0 blue:pixel[2] / 255.0 alpha:1];
  [self applyColors];
}

#pragma mark - lifecycle

- (void)emit:(NSString *)type direction:(NSString *)direction detail:(NSString *)detail
{
  RNCPageCurlLog(@"[page-curl] emit type=%@ direction=%@ detail=%@", type, direction, detail);
  if (self.onEvent) {
    self.onEvent(@{
      @"type": type,
      @"direction": direction ?: @"",
      @"detail": detail ?: @"",
    });
  }
}

- (void)setEnabled:(BOOL)enabled
{
  RNCPageCurlLog(@"[page-curl] setEnabled %d (was %d) host=%@ web=%@", enabled, _enabled, _hostView, _webView);
  if (enabled == _enabled) {
    return;
  }
  if (!enabled) {
    [self teardown];
    return;
  }
  UIView *host = _hostView;
  if (host == nil || _webView == nil) {
    RNCPageCurlLog(@"[page-curl] cannot enable: host or webview missing");
    return;
  }
  _enabled = YES;
  _spread = [self.spine isEqualToString:@"middle"];
  RNCPageCurlLog(@"[page-curl] spine prop=%@ -> spread=%d", self.spine, _spread);

  _renderer = [[RNCPageCurlRenderer alloc] initWithFrame:host.bounds];
  _renderer.hidden = YES;
  [host addSubview:_renderer];
  _inputBlocker = [[UIView alloc] initWithFrame:host.bounds];
  _inputBlocker.backgroundColor = [UIColor clearColor];
  _inputBlocker.hidden = YES;
  [host addSubview:_inputBlocker];
  [self applyColors];
  [self applyTuning];
  [self showCover];
  // nothing is baked yet; the manager's first settle starts the first bake
  [self setState:RNCPageCurlStateAwaitingSettle reason:@"enabled"];

  __weak __typeof(self) weakSelf = self;
  _touchObserver = [RNCPageCurlTouchObserver new];
  _touchObserver.cancelsTouchesInView = NO;
  _touchObserver.delaysTouchesBegan = NO;
  _touchObserver.delaysTouchesEnded = NO;
  _touchObserver.onTouchesBegan = ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    UIView *hit = strongSelf->_touchObserver.touch.view;
    strongSelf->_touchReachedWebView = hit != nil && strongSelf->_webView != nil && [hit isDescendantOfView:strongSelf->_webView];
    RNCPageCurlLog(@"[page-curl] touches began; state=%@ reachedWebView=%d", RNCPageCurlStateName(strongSelf->_state), strongSelf->_touchReachedWebView);
    [strongSelf makeWebPansYieldToCurl];
    [strongSelf emit:@"touch" direction:nil detail:nil];
  };
  _touchObserver.onTouchesEnded = ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    BOOL moved = strongSelf->_touchObserver.moved;
    RNCPageCurlLog(@"[page-curl] touches ended; moved=%d state=%@ reachedWebView=%d", moved, RNCPageCurlStateName(strongSelf->_state),
                   strongSelf->_touchReachedWebView);
    if (!moved && strongSelf->_touchReachedWebView && strongSelf->_state == RNCPageCurlStateIdle) {
      [strongSelf setState:RNCPageCurlStateAwaitingTapResult reason:@"tap"];
      [strongSelf emit:@"tap" direction:nil detail:nil];
    }
  };
  _touchObserver.onHeldStill = ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf->_pan == nil) {
      return;
    }
    // a still hold is a text-selection intent, not a page drag: fail the curl pan so
    // WebKit's long-press recognizers (which now wait on it) can proceed
    if (strongSelf->_pan.state == UIGestureRecognizerStatePossible) {
      RNCPageCurlLog(@"[page-curl] held still for 350ms; releasing the curl pan for this touch");
      strongSelf->_pan.enabled = NO;
      strongSelf->_pan.enabled = YES;
    }
  };
  [host addGestureRecognizer:_touchObserver];

  _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
  _pan.maximumNumberOfTouches = 1;
  _pan.delegate = self;
  [host addGestureRecognizer:_pan];
  RNCPageCurlLog(@"[page-curl] attached pan %@ to host", _pan);
  [self makeWebPansYieldToCurl];
}

// touch scrolling off in every scroll view inside the webview (rescanned at each touch-down: WebKit
// adds more as chunks load) and its pans wait for the curl pan; not undone, the caller remounts
- (void)makeWebPansYieldToCurl
{
  if (_webView == nil || _pan == nil) {
    return;
  }
  NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:_webView];
  NSUInteger recognizers = 0;
  NSUInteger scrollViews = 0;
  while (stack.count > 0) {
    UIView *view = stack.lastObject;
    [stack removeLastObject];
    if ([view isKindOfClass:[UIScrollView class]]) {
      UIScrollView *scrollView = (UIScrollView *)view;
      if (scrollView.scrollEnabled) {
        scrollView.scrollEnabled = NO;
        scrollViews += 1;
      }
    }
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
      BOOL isPan = [recognizer isKindOfClass:[UIPanGestureRecognizer class]];
      BOOL isLongPress = [recognizer isKindOfClass:[UILongPressGestureRecognizer class]];
      if ((isPan || isLongPress) && recognizer != _pan) {
        [recognizer requireGestureRecognizerToFail:_pan];
        recognizers += 1;
      }
    }
    [stack addObjectsFromArray:view.subviews];
  }
  RNCPageCurlLog(@"[page-curl] web scrolling off: %lu scroll views changed, %lu recognizers yield to the curl pan",
        (unsigned long)scrollViews, (unsigned long)recognizers);
}

- (void)setSpine:(NSString *)spine
{
  if ([_spine isEqualToString:spine] || (_spine == nil && spine == nil)) {
    return;
  }
  _spine = [spine copy];
  RNCPageCurlLog(@"[page-curl] spine changed to %@ (enabled=%d)", spine, _enabled);
  if (_enabled) {
    [self teardown];
    [self setEnabled:YES];
    [self requestRebake:@"spine change"];
  }
}

// bakes no longer match the page; the manager settles again once the page has painted. A busy
// controller needs nothing: the settle the manager sends is kept and applied when the controller frees
- (void)requestRebake:(NSString *)reason
{
  RNCPageCurlLog(@"[page-curl] rebake requested (%@) state=%@", reason, RNCPageCurlStateName(_state));
  [self awaitSettleIfResting:reason];
  NSUInteger serial = _stateSerial;
  __weak __typeof(self) weakSelf = self;
  [self callBridge:@"invalidateNativePageCurl" argument:nil completion:^(BOOL ok, id result) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (ok || strongSelf == nil || strongSelf->_stateSerial != serial || strongSelf->_state != RNCPageCurlStateAwaitingSettle) {
      return;
    }
    // no settle is coming: open input with nothing to curl onto until the manager settles on its own
    [strongSelf blankAllSlots];
    [strongSelf setState:RNCPageCurlStateIdle reason:@"rebake request failed"];
  }];
}

// the manager is about to move the page: a controller resting on it (idle, or waiting on a tap's
// result) waits for the settle
- (void)awaitSettleIfResting:(NSString *)reason
{
  if (_state == RNCPageCurlStateIdle || _state == RNCPageCurlStateAwaitingTapResult) {
    [self setState:RNCPageCurlStateAwaitingSettle reason:reason];
  }
}

- (void)teardown
{
  RNCPageCurlLog(@"[page-curl] teardown");
  _enabled = NO;
  _teardownCount += 1;
  _stateSerial += 1;
  _awaitingLanding = NO;
  _failedBakes = 0;
  [self stopAnimation];
  if (_pan != nil) {
    [_pan.view removeGestureRecognizer:_pan];
    _pan = nil;
  }
  if (_touchObserver != nil) {
    [_touchObserver.view removeGestureRecognizer:_touchObserver];
    _touchObserver = nil;
  }
  [_renderer removeFromSuperview];
  _renderer = nil;
  [_inputBlocker removeFromSuperview];
  _inputBlocker = nil;
  _turnDirection = nil;
  _edgeEmitted = NO;
  _pendingSettle = nil;
  _state = RNCPageCurlStateIdle;
}

- (void)layoutWithBounds:(CGRect)bounds
{
  if (_renderer == nil) {
    return;
  }
  _renderer.frame = bounds;
  _inputBlocker.frame = bounds;
  BOOL resized = !CGSizeEqualToSize(_lastSize, CGSizeZero) && !CGSizeEqualToSize(_lastSize, bounds.size);
  _lastSize = bounds.size;
  if (resized) {
    [self requestRebake:@"resize"];
  }
}

#pragma mark - slots

- (RNCPageCurlSlot *)slot:(NSString *)name
{
  return _slots[name] ?: _slots[RNCPageCurlSlotCurrent];
}

// after a turn the displayed slot becomes "current" and the two others rotate with it;
// the slot that fell off the far side is the only one that needs a new bake
- (void)rotateSlotsToward:(NSString *)direction
{
  RNCPageCurlSlot *previous = _slots[RNCPageCurlSlotPrevious];
  RNCPageCurlSlot *current = _slots[RNCPageCurlSlotCurrent];
  RNCPageCurlSlot *next = _slots[RNCPageCurlSlotNext];
  if ([direction isEqualToString:RNCPageCurlSlotNext]) {
    _slots[RNCPageCurlSlotPrevious] = current;
    _slots[RNCPageCurlSlotCurrent] = next;
    _slots[RNCPageCurlSlotNext] = previous;
    [self blankSlot:RNCPageCurlSlotNext];
  } else {
    _slots[RNCPageCurlSlotNext] = current;
    _slots[RNCPageCurlSlotCurrent] = previous;
    _slots[RNCPageCurlSlotPrevious] = next;
    [self blankSlot:RNCPageCurlSlotPrevious];
  }
  RNCPageCurlLog(@"[page-curl] rotated slots toward %@", direction);
}

- (void)bakeImage:(UIImage *)image intoSlot:(NSString *)name
{
  RNCPageCurlSlot *slot = [self slot:name];
  slot.texture = image != nil ? [_renderer textureFromImage:image] : nil;
  slot.hasPage = YES;
}

- (void)clearSlot:(NSString *)name
{
  RNCPageCurlLog(@"[page-curl] clear slot=%@ (no page)", name);
  [self slot:name].texture = nil;
  [self slot:name].hasPage = NO;
}

- (void)blankSlot:(NSString *)name
{
  RNCPageCurlLog(@"[page-curl] blank slot=%@ (page exists, not baked)", name);
  [self slot:name].texture = nil;
  [self slot:name].hasPage = YES;
}

- (void)blankAllSlots
{
  for (NSString *slot in @[RNCPageCurlSlotPrevious, RNCPageCurlSlotCurrent, RNCPageCurlSlotNext]) {
    [self blankSlot:slot];
  }
}

#pragma mark - scenes

- (CGRect)fullTexRect
{
  return CGRectMake(0, 0, 1, 1);
}

- (CGRect)leftTexRect
{
  return CGRectMake(0, 0, 0.5, 1);
}

- (CGRect)rightTexRect
{
  return CGRectMake(0.5, 0, 0.5, 1);
}

- (CGRect)leftHalf
{
  CGRect bounds = _renderer.bounds;
  return CGRectMake(0, 0, bounds.size.width / 2, bounds.size.height);
}

- (CGRect)rightHalf
{
  CGRect bounds = _renderer.bounds;
  return CGRectMake(bounds.size.width / 2, 0, bounds.size.width / 2, bounds.size.height);
}

// the current bake, flat, covering the whole view
- (void)showCover
{
  RNCPageCurlSlot *current = [self slot:RNCPageCurlSlotCurrent];
  _renderer.underPages = @[[RNCPageCurlPage pageWithTexture:current.texture rect:_renderer.bounds texRect:[self fullTexRect]]];
  _renderer.sheet = nil;
  _renderer.sheetBackTexture = nil;
  _renderer.curling = NO;
  [_renderer draw];
}

// pages of the turn toward `direction`: what lies underneath, the sheet and what is on its back
- (void)showTurnScene:(NSString *)direction
{
  BOOL next = [direction isEqualToString:RNCPageCurlSlotNext];
  RNCPageCurlSlot *current = [self slot:RNCPageCurlSlotCurrent];
  RNCPageCurlSlot *target = [self slot:direction];
  // one sheet hinged at the left edge turns back by unfolding, so only the spread's turn back is mirrored
  _turnMirrored = _spread && !next;
  _renderer.mirrored = _turnMirrored;
  if (!_spread) {
    if (next) {
      _renderer.underPages = @[[RNCPageCurlPage pageWithTexture:target.texture rect:_renderer.bounds texRect:[self fullTexRect]]];
      _renderer.sheet = [RNCPageCurlPage pageWithTexture:current.texture rect:_renderer.bounds texRect:[self fullTexRect]];
    } else {
      _renderer.underPages = @[[RNCPageCurlPage pageWithTexture:current.texture rect:_renderer.bounds texRect:[self fullTexRect]]];
      _renderer.sheet = [RNCPageCurlPage pageWithTexture:target.texture rect:_renderer.bounds texRect:[self fullTexRect]];
    }
    _renderer.sheetBackTexture = nil;
  } else if (next) {
    _renderer.underPages = @[
      [RNCPageCurlPage pageWithTexture:current.texture rect:[self leftHalf] texRect:[self leftTexRect]],
      [RNCPageCurlPage pageWithTexture:target.texture rect:[self rightHalf] texRect:[self rightTexRect]],
    ];
    _renderer.sheet = [RNCPageCurlPage pageWithTexture:current.texture rect:[self rightHalf] texRect:[self rightTexRect]];
    _renderer.sheetBackTexture = target.texture;
    _renderer.sheetBackTexRect = [self leftTexRect];
  } else {
    _renderer.underPages = @[
      [RNCPageCurlPage pageWithTexture:target.texture rect:[self leftHalf] texRect:[self leftTexRect]],
      [RNCPageCurlPage pageWithTexture:current.texture rect:[self rightHalf] texRect:[self rightTexRect]],
    ];
    _renderer.sheet = [RNCPageCurlPage pageWithTexture:current.texture rect:[self leftHalf] texRect:[self leftTexRect]];
    _renderer.sheetBackTexture = target.texture;
    _renderer.sheetBackTexRect = [self rightTexRect];
  }
  _renderer.curling = YES;
  _turnSheetRect = _renderer.sheet.rect;
  NSMutableString *scene = [NSMutableString string];
  for (RNCPageCurlPage *page in _renderer.underPages) {
    [scene appendFormat:@" under rect=%@ tex=%@ %@;", NSStringFromCGRect(page.rect), NSStringFromCGRect(page.texRect), page.texture ? @"image" : @"paper"];
  }
  [scene appendFormat:@" sheet rect=%@ tex=%@ %@ back=%@ %@", NSStringFromCGRect(_turnSheetRect), NSStringFromCGRect(_renderer.sheet.texRect),
   _renderer.sheet.texture ? @"image" : @"paper", NSStringFromCGRect(_renderer.sheetBackTexRect), _renderer.sheetBackTexture ? @"image" : @"color"];
  RNCPageCurlLog(@"[page-curl] scene %@ mirrored=%d:%@", direction, _turnMirrored, scene);
}

#pragma mark - webview bridge

- (void)snapshotIntoSlot:(NSString *)slot completion:(void (^)(BOOL ok))completion
{
  WKWebView *webView = _webView;
  if (webView == nil) {
    RNCPageCurlLog(@"[page-curl] snapshot slot=%@ failed: webview missing", slot);
    completion(NO);
    return;
  }
  WKSnapshotConfiguration *config = [WKSnapshotConfiguration new];
  config.afterScreenUpdates = YES;
  CFTimeInterval start = CACurrentMediaTime();
  NSUInteger teardownCount = _teardownCount;
  __weak __typeof(self) weakSelf = self;
  [webView takeSnapshotWithConfiguration:config completionHandler:^(UIImage *image, NSError *error) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    double ms = (CACurrentMediaTime() - start) * 1000.0;
    RNCPageCurlLog(@"[page-curl] snapshot slot=%@ took %.1fms image=%@ error=%@", slot, ms, NSStringFromCGSize(image.size), error);
    if (teardownCount != strongSelf->_teardownCount) {
      RNCPageCurlLog(@"[page-curl] snapshot slot=%@ dropped: the controller was torn down", slot);
      completion(NO);
      return;
    }
    if (error != nil || image == nil) {
      completion(NO);
      return;
    }
    [strongSelf bakeImage:image intoSlot:slot];
    if ([slot isEqualToString:RNCPageCurlSlotCurrent] && strongSelf->_paperColor == nil) {
      [strongSelf adoptPaperColorFrom:image];
    }
    completion(YES);
  }];
}

// window.s.<fn>(argument) in the content frame: the manager's own methods, awaited when they return a promise
- (void)callBridge:(NSString *)fn argument:(id)argument completion:(void (^)(BOOL ok, id result))completion
{
  WKWebView *webView = _webView;
  if (webView == nil) {
    RNCPageCurlLog(@"[page-curl] bridge %@(%@) failed: webview missing", fn, argument);
    completion(NO, nil);
    return;
  }
  NSString *body = [NSString stringWithFormat:
      @"if (!window.s || !window.s.%@) { throw new Error('scrolling manager has no %@'); }"
       "return await window.s.%@(argument);", fn, fn, fn];
  CFTimeInterval start = CACurrentMediaTime();
  [webView callAsyncJavaScript:body
                     arguments:@{@"argument": argument ?: [NSNull null]}
                       inFrame:nil
                inContentWorld:WKContentWorld.pageWorld
             completionHandler:^(id result, NSError *error) {
    double ms = (CACurrentMediaTime() - start) * 1000.0;
    RNCPageCurlLog(@"[page-curl] bridge %@(%@) took %.1fms result=%@ error=%@", fn, argument, ms, result, error);
    completion(error == nil, result);
  }];
}

#pragma mark - bakes

- (RNCPageCurlStep)stepSnapshot:(NSString *)slot
{
  __weak __typeof(self) weakSelf = self;
  return ^(void (^done)(BOOL)) {
    [weakSelf snapshotIntoSlot:slot completion:^(BOOL ok) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf == nil) {
        done(NO);
        return;
      }
      // a neighbor that failed to bake stays blank and is not curled onto; a failed current bake has no cover to show
      if (!ok && ![slot isEqualToString:RNCPageCurlSlotCurrent]) {
        [strongSelf blankSlot:slot];
        done(YES);
        return;
      }
      done(ok);
    }];
  };
}

// parks the webview on a page of the current chunk; done once that page has painted
- (RNCPageCurlStep)stepJumpToPage:(NSInteger)page
{
  __weak __typeof(self) weakSelf = self;
  return ^(void (^done)(BOOL)) {
    [weakSelf callBridge:@"nativePageCurlJump" argument:@(page) completion:^(BOOL ok, id result) {
      done(ok);
    }];
  };
}

- (RNCPageCurlStep)stepBlock:(void (^)(void))block
{
  return ^(void (^done)(BOOL)) {
    block();
    done(YES);
  };
}

// a bake runs every step to the end; only a teardown stops it, and then it stops without reporting
- (void)runSteps:(NSArray<RNCPageCurlStep> *)steps index:(NSUInteger)index teardownCount:(NSUInteger)teardownCount completion:(void (^)(BOOL ok))completion
{
  if (teardownCount != _teardownCount) {
    RNCPageCurlLog(@"[page-curl] bake stopped at step %lu: controller torn down", (unsigned long)index);
    return;
  }
  if (index >= steps.count) {
    completion(YES);
    return;
  }
  __weak __typeof(self) weakSelf = self;
  steps[index](^(BOOL ok) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    if (teardownCount != strongSelf->_teardownCount) {
      RNCPageCurlLog(@"[page-curl] bake stopped after step %lu: controller torn down", (unsigned long)index);
      return;
    }
    if (!ok) {
      completion(NO);
      return;
    }
    [strongSelf runSteps:steps index:index + 1 teardownCount:teardownCount completion:completion];
  });
}

// the slot beyond the target page: baked from this chunk, from the neighbouring chunk's edge page
// through the manager's own chunk switch (blank paper if refused), or cleared at the ends of the book
- (void)addNeighborStepsForPage:(NSInteger)page direction:(NSString *)direction to:(NSMutableArray<RNCPageCurlStep> *)steps
{
  BOOL next = [direction isEqualToString:RNCPageCurlSlotNext];
  NSInteger neighbor = next ? page + 1 : page - 1;
  BOOL exists = next ? page < _lastPage : page > 0;
  BOOL beyondChunk = next ? !_isLastChunk : _chunkIndex > 0;
  if (exists) {
    [steps addObject:[self stepJumpToPage:neighbor]];
    [steps addObject:[self stepSnapshot:direction]];
    return;
  }
  __weak __typeof(self) weakSelf = self;
  if (!beyondChunk) {
    [steps addObject:[self stepBlock:^{
      [weakSelf clearSlot:direction];
    }]];
    return;
  }
  // peek, snapshot and unpeek are one step, so the manager is never left peeked between steps
  [steps addObject:^(void (^done)(BOOL)) {
    [weakSelf callBridge:@"nativePageCurlPeek" argument:direction completion:^(BOOL ok, id result) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf == nil) {
        return;
      }
      if (!ok || ![result isKindOfClass:[NSNumber class]] || ![result boolValue]) {
        RNCPageCurlLog(@"[page-curl] peek %@ refused; that side stays blank", direction);
        [strongSelf blankSlot:direction];
        done(YES);
        return;
      }
      [strongSelf snapshotIntoSlot:direction completion:^(BOOL snapped) {
        __strong __typeof(weakSelf) innerSelf = weakSelf;
        if (!snapped && innerSelf != nil) {
          [innerSelf blankSlot:direction];
        }
        [weakSelf callBridge:@"nativePageCurlUnpeek" argument:nil completion:^(BOOL unpeeked, id unpeekResult) {
          done(unpeeked);
        }];
      }];
    }];
  }];
}

// every slot from scratch; the settle says which page the webview rests on
- (void)runBakeWithSettle:(NSDictionary *)settle
{
  _pendingSettle = nil;
  _awaitingLanding = NO;
  _edgeEmitted = NO;
  _page = [settle[@"page"] integerValue];
  _lastPage = [settle[@"totalPages"] integerValue];
  _chunkIndex = [settle[@"chunkIndex"] integerValue];
  _isLastChunk = [settle[@"isLastChunk"] boolValue];
  [self setState:RNCPageCurlStateBaking reason:@"settle"];
  NSUInteger teardownCount = _teardownCount;
  CFTimeInterval start = CACurrentMediaTime();
  RNCPageCurlLog(@"[page-curl] bake start page=%ld/%ld chunk=%ld last=%d", (long)_page, (long)_lastPage, (long)_chunkIndex, _isLastChunk);

  __weak __typeof(self) weakSelf = self;
  NSMutableArray<RNCPageCurlStep> *steps = [NSMutableArray array];
  // a relayout may have left the webview on another page
  [steps addObject:[self stepJumpToPage:_page]];
  [steps addObject:[self stepSnapshot:RNCPageCurlSlotCurrent]];
  [steps addObject:[self stepBlock:^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    [strongSelf showCover];
    strongSelf->_renderer.hidden = NO;
  }]];
  BOOL moved = _page < _lastPage || _page > 0;
  [self addNeighborStepsForPage:_page direction:RNCPageCurlSlotNext to:steps];
  [self addNeighborStepsForPage:_page direction:RNCPageCurlSlotPrevious to:steps];
  if (moved) {
    [steps addObject:[self stepJumpToPage:_page]];
  }
  [self runSteps:steps index:0 teardownCount:teardownCount completion:^(BOOL ok) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    RNCPageCurlLog(@"[page-curl] bake %@ in %.1fms", ok ? @"done" : @"FAILED", (CACurrentMediaTime() - start) * 1000.0);
    [strongSelf finishBake:ok];
  }];
}

// a settle that arrived while the controller was busy starts the next bake under the same cover
- (void)bakePendingOrIdle:(NSString *)reason
{
  if (_pendingSettle != nil) {
    RNCPageCurlLog(@"[page-curl] baking again: a settle arrived meanwhile");
    [self runBakeWithSettle:_pendingSettle];
    return;
  }
  [self setState:RNCPageCurlStateIdle reason:reason];
}

// a finished bake opens input; one that stopped early blanks its slots, which describe another page,
// then bakes a kept settle, asks the manager for a new one, or gives up at the cap
- (void)finishBake:(BOOL)ok
{
  if (ok) {
    _failedBakes = 0;
    [self bakePendingOrIdle:@"baked"];
    return;
  }
  [self blankAllSlots];
  if (_pendingSettle != nil) {
    [self runBakeWithSettle:_pendingSettle];
    return;
  }
  _failedBakes += 1;
  if (_failedBakes >= RNCPageCurlMaxFailedBakes) {
    // taps still turn pages; the next settle the manager sends on its own bakes again
    RNCPageCurlLog(@"[page-curl] %lu bakes failed in a row; no curl until the next settle", (unsigned long)_failedBakes);
    [self setState:RNCPageCurlStateIdle reason:@"bakes kept failing"];
    return;
  }
  [self setState:RNCPageCurlStateAwaitingSettle reason:@"bake failed"];
  [self requestRebake:@"bake failed"];
}

#pragma mark - messages from the content frame

- (void)handleMessage:(NSDictionary *)message
{
  NSString *type = message[@"type"];
  RNCPageCurlLog(@"[page-curl] message %@ (state=%@ pending=%d)", message, RNCPageCurlStateName(_state), _pendingSettle != nil);
  if (_renderer == nil) {
    return;
  }
  if ([type isEqualToString:@"settled"]) {
    [self emit:@"settled" direction:nil detail:[NSString stringWithFormat:@"page %@/%@ chunk %@", message[@"page"], message[@"totalPages"], message[@"chunkIndex"]]];
    if (_state == RNCPageCurlStateBaking || _state == RNCPageCurlStateAnimating) {
      RNCPageCurlLog(@"[page-curl] settle kept until the %@ ends", RNCPageCurlStateName(_state));
      _pendingSettle = message;
      return;
    }
    // posted during the turn, delivered after it landed: it names the page the reader just left
    if (_awaitingLanding && [message[@"page"] integerValue] == _page && [message[@"chunkIndex"] integerValue] == _chunkIndex) {
      RNCPageCurlLog(@"[page-curl] settle for the page just left; dropped");
      return;
    }
    [self runBakeWithSettle:message];
    return;
  }
  if ([type isEqualToString:@"unsettled"]) {
    // the manager posts this before it moves, so every settle after it is from after the landing
    _awaitingLanding = NO;
    [self awaitSettleIfResting:@"unsettled"];
    return;
  }
  if ([type isEqualToString:@"touchEnd"]) {
    if (_state == RNCPageCurlStateAwaitingTapResult) {
      [self setState:RNCPageCurlStateIdle reason:@"tap turned no page"];
    }
    return;
  }
  RNCPageCurlLog(@"[page-curl] unknown message type %@", type);
}

#pragma mark - state

- (void)setState:(RNCPageCurlState)state reason:(NSString *)reason
{
  if (state != _state) {
    RNCPageCurlLog(@"[page-curl] %@ -> %@ (%@)", RNCPageCurlStateName(_state), RNCPageCurlStateName(state), reason);
    _stateSerial += 1;
  }
  _state = state;
  // both overlays follow the state: idle is the webview, bare, with touches reaching it
  _inputBlocker.hidden = state == RNCPageCurlStateIdle;
  if (state == RNCPageCurlStateIdle) {
    _renderer.hidden = YES;
    [self emit:@"ready" direction:nil detail:reason];
    [self beginTurnForPan];
  }
}

- (BOOL)panActive
{
  return _pan.state == UIGestureRecognizerStateBegan || _pan.state == UIGestureRecognizerStateChanged;
}

#pragma mark - gestures

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
  if (gestureRecognizer != _pan) {
    return YES;
  }
  // the curl pan claims every drag while the curl is on, so WebKit's pans never scroll the page
  // themselves; if the controller is busy the turn starts once it is idle
  RNCPageCurlLog(@"[page-curl] pan should begin? state=%@", RNCPageCurlStateName(_state));
  return _state != RNCPageCurlStateAnimating;
}

// the active pan's turn, from its original touch-down: the pan's own translation restarts from zero
// where recognition began, and a pan that began while the controller was busy starts here once it is idle
- (void)beginTurnForPan
{
  if (![self panActive] || _turnDirection != nil || _turnDeclined || _state != RNCPageCurlStateIdle) {
    return;
  }
  CGPoint touchDown = _touchObserver.startPoint;
  CGPoint location = [_pan locationInView:_hostView];
  CGFloat dx = location.x - touchDown.x;
  if (dx == 0) {
    return;
  }
  [self beginTurn:dx < 0 ? RNCPageCurlSlotNext : RNCPageCurlSlotPrevious from:touchDown];
  _turnDeclined = _turnDirection == nil;
  if (_turnDirection != nil) {
    [self moveTurnTo:location];
  }
}

- (void)onPan:(UIPanGestureRecognizer *)pan
{
  CGPoint location = [pan locationInView:_hostView];
  RNCPageCurlLog(@"[page-curl] pan state=%ld location=%.1f,%.1f touchDown=%@ curlState=%@ turn=%@", (long)pan.state, location.x, location.y,
                      NSStringFromCGPoint(_touchObserver.startPoint), RNCPageCurlStateName(_state), _turnDirection);
  BOOL moving = pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged;
  if (_turnDirection == nil && moving) {
    if (_state != RNCPageCurlStateIdle && pan.state == UIGestureRecognizerStateBegan) {
      RNCPageCurlLog(@"[page-curl] pan began while %@; holding the drag until idle", RNCPageCurlStateName(_state));
    }
    [self beginTurnForPan];
    return;
  }
  if (_turnDirection == nil) {
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
      _turnDeclined = NO;
      RNCPageCurlLog(@"[page-curl] pan ended without a turn (state=%@)", RNCPageCurlStateName(_state));
    }
    return;
  }
  if (moving) {
    [self moveTurnTo:location];
    return;
  }
  if (pan.state == UIGestureRecognizerStateEnded) {
    [self releaseTurnWithVelocity:[pan velocityInView:_hostView]];
    return;
  }
  if (pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
    RNCPageCurlLog(@"[page-curl] pan cancelled by the system; the turn cancels");
    [self endTurnCompleting:NO velocity:CGPointZero];
  }
}

#pragma mark - turns

- (void)beginTurn:(NSString *)direction from:(CGPoint)start
{
  RNCPageCurlSlot *target = [self slot:direction];
  if (!target.hasPage) {
    RNCPageCurlLog(@"[page-curl] no page toward %@; no curl", direction);
    return;
  }
  // a page that exists but was never baked is never curled onto: the sheet would lift onto blank paper
  if (target.texture == nil) {
    if (!_edgeEmitted) {
      _edgeEmitted = YES;
      [self emit:@"edge" direction:direction detail:nil];
    }
    RNCPageCurlLog(@"[page-curl] page toward %@ not baked; no curl", direction);
    return;
  }
  BOOL next = [direction isEqualToString:RNCPageCurlSlotNext];
  _turnDirection = direction;
  _turnReversed = !next && !_spread;
  [self setState:RNCPageCurlStateAnimating reason:@"turn begins"];
  [self showTurnScene:direction];
  CGFloat width = _turnSheetRect.size.width;
  CGFloat height = _turnSheetRect.size.height;
  _turnRadiusMax = MIN([self tune:@"radiusMax"], width * [self tune:@"radiusFraction"]);
  _renderer.curlRadiusMax = _turnRadiusMax;
  // the sheet is grabbed at its outer edge on the touch's row, wherever the touch lands, and that
  // edge moves exactly as far as the finger does
  _turnStart = CGPointMake(width, MIN(MAX(start.y - _turnSheetRect.origin.y, 0), height));
  _turnRest = _turnReversed ? [self turnedFinger] : _turnStart;
  _turnTouchDown = CGPointMake([self localXFor:start.x], start.y - _turnSheetRect.origin.y);
  _turnDrag = 0;
  _renderer.curlStart = _turnStart;
  RNCPageCurlLog(@"[page-curl] turn %@ begins at %@ grab=%@ sheet=%@ mirrored=%d reversed=%d radiusMax=%.0f", direction, NSStringFromCGPoint(start),
        NSStringFromCGPoint(_turnStart), NSStringFromCGRect(_turnSheetRect), _turnMirrored, _turnReversed, _turnRadiusMax);
  [self applyFinger:_turnRest];
  // the layer would otherwise show whatever it drew last for a frame
  [_renderer draw];
  _renderer.hidden = NO;
}

- (CGFloat)localXFor:(CGFloat)x
{
  return _turnMirrored ? CGRectGetMaxX(_turnSheetRect) - x : x - _turnSheetRect.origin.x;
}

// where the grabbed point sits once the sheet lies flat on the other side: mirrored across the spine,
// less the part of the flattening that settleGain lets the finger skip
- (CGPoint)turnedFinger
{
  CGFloat gain = MAX([self tune:@"settleGain"], 1);
  CGFloat skipped = M_PI * _turnRadiusMax * (1 - 1 / gain);
  return CGPointMake(-_turnStart.x + skipped, _turnStart.y);
}

// the grabbed point follows the finger 1:1
- (void)moveTurnTo:(CGPoint)location
{
  CGPoint local = CGPointMake([self localXFor:location.x], location.y - _turnSheetRect.origin.y);
  _turnDrag = _turnReversed ? local.x - _turnTouchDown.x : _turnTouchDown.x - local.x;
  CGPoint finger = CGPointMake(_turnRest.x + local.x - _turnTouchDown.x, _turnRest.y + local.y - _turnTouchDown.y);
  finger.x = MIN(MAX(finger.x, [self turnedFinger].x), _turnStart.x);
  finger.y = MIN(MAX(finger.y, 0), _turnSheetRect.size.height);
  [self applyFinger:finger];
}

- (void)applyFinger:(CGPoint)finger
{
  CGFloat dx = MAX(_turnStart.x - finger.x, 0);
  CGFloat dy = _turnStart.y - finger.y;
  // the tilt follows the vertical offset against the horizontal drag plus tiltSoftness, so a small
  // vertical move tilts the fold a little instead of flipping it
  CGFloat soft = MAX([self tune:@"tiltSoftness"], 0);
  CGFloat ex = dx + soft;
  CGFloat norm = sqrt(ex * ex + dy * dy);
  CGFloat nx = 1, ny = 0;
  if (norm > 0.5) {
    nx = ex / norm;
    ny = dy / norm;
  }
  CGFloat distance = MAX(dx * nx + dy * ny, 0);
  // the fold, (distance + pi R) / 2 behind the grab point along n, must leave the whole spine (local
  // x = 0) on the flat side: the tilt gives way first, then the bend flattens, then the finger is held
  CGFloat farthest = MAX(_turnStart.y, _turnSheetRect.size.height - _turnStart.y);
  CGFloat room = _turnStart.x * nx - fabs(ny) * farthest;
  // paper lifts into its full curve as soon as it is pulled: the bend is complete bendInDistance into the drag
  CGFloat wantedRadius = _turnRadiusMax * MIN(1, distance / MAX([self tune:@"bendInDistance"], 1));
  CGFloat need = (distance + M_PI * wantedRadius) / 2;
  if (need > room && fabs(ny) > 0.0005) {
    // the largest tilt that leaves room for the full bend (room falls as the tilt grows)
    CGFloat low = 0, high = fabs(ny);
    for (int i = 0; i < 30; i++) {
      CGFloat mid = (low + high) / 2;
      CGFloat midRoom = _turnStart.x * sqrt(1 - mid * mid) - mid * farthest;
      if (need > midRoom) {
        high = mid;
      } else {
        low = mid;
      }
    }
    ny = copysign(low, ny);
    nx = sqrt(1 - ny * ny);
    room = _turnStart.x * nx - fabs(ny) * farthest;
  }
  if (distance / 2 > room) {
    nx = 1;
    ny = 0;
    room = _turnStart.x;
    distance = MIN(distance, 2 * room);
  }
  finger = CGPointMake(_turnStart.x - nx * distance, _turnStart.y - ny * distance);
  _turnFinger = finger;
  // once the fold reaches the spine the bend must flatten, which slides the sheet by pi R; settleGain
  // lets the finger drive that last phase faster so it takes fewer points of travel
  CGFloat gain = MAX([self tune:@"settleGain"], 1);
  CGFloat settleStart = M_PI * wantedRadius / 2;
  CGFloat foldFree = room - distance / 2;
  if (foldFree < settleStart) {
    foldFree = MAX(settleStart - (settleStart - foldFree) * gain, 0);
    distance = 2 * (room - foldFree);
    finger = CGPointMake(_turnStart.x - nx * distance, _turnStart.y - ny * distance);
  }
  CGFloat radius = MIN(wantedRadius, MAX(2 * (room - distance / 2) / M_PI, 0));
  // a zero drag is a flat sheet: while the bend forms, the fold starts past the outer edge and sweeps
  // in, instead of sitting at the grab point with everything beyond it mirrored onto itself
  CGFloat bendIn = MAX([self tune:@"bendInDistance"], 1);
  CGFloat settle = MAX(0, 1 - distance / bendIn);
  CGFloat foldOffset = settle * (_turnSheetRect.size.width - _turnStart.x + M_PI * radius / 2 + 4);
  CGFloat foldX = _turnStart.x + nx * foldOffset - nx * (distance + M_PI * radius) / 2;
  _renderer.curlStart = CGPointMake(_turnStart.x + nx * foldOffset, _turnStart.y + ny * foldOffset);
  _renderer.curlFinger = CGPointMake(finger.x + nx * foldOffset, finger.y + ny * foldOffset);
  _renderer.curlRadius = radius;
  _renderer.curlBendStrength = MIN(1, distance / MAX([self tune:@"bendDarkenIn"], 1));
  _turnFold = MIN(MAX((_turnStart.x - foldX) / MAX(_turnStart.x, 1), 0), 1);
  RNCPageCurlLog(@"[page-curl] finger %.1f,%.1f (grab=%.1f,%.1f distance=%.1f room=%.1f foldOffset=%.1f foldX=%.1f R=%.1f fold=%.2f)",
                      finger.x, finger.y, _turnStart.x, _turnStart.y, distance, room, foldOffset, foldX, radius, _turnFold);
  [_renderer setNeedsDisplay];
}

// 0 at the start of the turn, 1 when the page has fully turned
- (CGFloat)turnProgress
{
  return _turnReversed ? 1 - _turnFold : _turnFold;
}

- (void)releaseTurnWithVelocity:(CGPoint)velocity
{
  BOOL next = [_turnDirection isEqualToString:RNCPageCurlSlotNext];
  CGFloat toward = next ? -velocity.x : velocity.x;
  // the content frame's own swipe rule: a drag past completeDistance, or one whose average speed over
  // the touch beats flickVelocity, turns the page, unless the finger was moving back when it lifted
  CGFloat elapsed = MAX(CACurrentMediaTime() - _touchObserver.startTime, 0.001);
  CGFloat average = _turnDrag / elapsed;
  BOOL movingBack = toward < -50;
  BOOL completes = !movingBack && (_turnDrag > [self tune:@"completeDistance"] || average > [self tune:@"flickVelocity"]);
  RNCPageCurlLog(@"[page-curl] release velocity=%.0f drag=%.0f over %.0fms average=%.0f -> %@", velocity.x, _turnDrag, elapsed * 1000, average,
        completes ? @"complete" : @"cancel");
  [self endTurnCompleting:completes velocity:velocity];
}

- (void)endTurnCompleting:(BOOL)completes velocity:(CGPoint)velocity
{
  CGFloat progress = [self turnProgress];
  CGFloat speedMin = [self tune:@"speedMin"];
  CGFloat speed = MIN([self tune:@"speedMax"], MAX(speedMin, speedMin + fabs(velocity.x) / 3000.0));
  CGFloat remaining = completes ? 1 - progress : progress;
  CGFloat duration = ([self tune:@"durationBase"] + [self tune:@"durationPerRemaining"] * remaining) / speed;
  BOOL endsTurned = completes != _turnReversed;
  RNCPageCurlLog(@"[page-curl] turn %@ from progress=%.2f in %.0fms", completes ? @"completes" : @"cancels", progress, duration * 1000);
  [self animateFingerTo:endsTurned ? [self turnedFinger] : _turnStart duration:duration completes:completes];
}

- (void)animateFingerTo:(CGPoint)target duration:(CFTimeInterval)duration completes:(BOOL)completes
{
  [self stopAnimation];
  _animationFrom = _turnFinger;
  _animationTo = target;
  _animationStart = CACurrentMediaTime();
  _animationDuration = MAX(duration, 0.01);
  _animationCompletes = completes;
  _animation = [CADisplayLink displayLinkWithTarget:self selector:@selector(onAnimationTick:)];
  [_animation addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)onAnimationTick:(CADisplayLink *)link
{
  CGFloat t = MIN(1, (CACurrentMediaTime() - _animationStart) / _animationDuration);
  CGFloat eased = RNCPageCurlEaseOut(t);
  CGPoint finger = CGPointMake(_animationFrom.x + (_animationTo.x - _animationFrom.x) * eased,
                               _animationFrom.y + (_animationTo.y - _animationFrom.y) * eased);
  [self applyFinger:finger];
  if (t >= 1) {
    BOOL completes = _animationCompletes;
    [self stopAnimation];
    [self finishTurnCompleted:completes];
  }
}

- (void)stopAnimation
{
  [_animation invalidate];
  _animation = nil;
}

- (void)finishTurnCompleted:(BOOL)completed
{
  NSString *direction = _turnDirection;
  _turnDirection = nil;
  _edgeEmitted = NO;
  RNCPageCurlLog(@"[page-curl] turn %@ finished completed=%d", direction, completed);
  if (!completed) {
    [self showCover];
    [self emit:@"cancel" direction:nil detail:nil];
    // the three bakes are still valid
    [self bakePendingOrIdle:@"turn cancelled"];
    return;
  }
  [self emit:@"turn" direction:direction detail:[NSString stringWithFormat:@"from page %ld", (long)_page]];
  // the cover shows the landed page; the manager turns to it the way a margin tap does, and its
  // settle bakes every slot again. Past the chunk edge that is the manager's own chunk switch
  [self rotateSlotsToward:direction];
  [self showCover];
  // a settle from during the turn describes the page just left; the landing produces a fresh one
  _pendingSettle = nil;
  _awaitingLanding = YES;
  [self setState:RNCPageCurlStateAwaitingSettle reason:@"turn landed"];
  NSString *fn = [direction isEqualToString:RNCPageCurlSlotNext] ? @"instantlyScrollPageDown" : @"instantlyScrollPageUp";
  RNCPageCurlLog(@"[page-curl] turn landed toward %@; %@", direction, fn);
  __weak __typeof(self) weakSelf = self;
  [self callBridge:fn argument:nil completion:^(BOOL ok, id result) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (!ok && strongSelf != nil) {
      // the webview never moved, so the settle it sends names the page the turn started on
      strongSelf->_awaitingLanding = NO;
      [strongSelf requestRebake:@"landing failed"];
    }
  }];
  // only the manager's settle leaves this state; say so if it has not come
  NSUInteger serial = _stateSerial;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf != nil && strongSelf->_stateSerial == serial) {
      RNCPageCurlLog(@"[page-curl] no settle 3s after landing toward %@; still awaiting it", direction);
    }
  });
}

@end
