#import "RNCWebViewPageCurl.h"
#import "RNCPageCurlRenderer.h"
#import <UIKit/UIGestureRecognizerSubclass.h>

static NSString *const RNCPageCurlSlotCurrent = @"current";
static NSString *const RNCPageCurlSlotPrevious = @"previous";
static NSString *const RNCPageCurlSlotNext = @"next";

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
    @"completeFraction": @0.5,
    @"flickVelocity": @300,
    @"durationBase": @0.18,
    @"durationPerRemaining": @0.32,
    @"speedMin": @0.45,
    @"speedMax": @1.3,
  };
}

typedef void (^RNCPageCurlStep)(void (^done)(BOOL ok));

// #rgb, #rrggbb, #rrggbbaa, rgb(r, g, b), rgba(r, g, b, a), white, black
static UIColor *RNCPageCurlColorFromCSS(NSString *css)
{
  NSString *value = [[css stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
  if (value.length == 0) {
    return nil;
  }
  if ([value isEqualToString:@"white"]) {
    return [UIColor whiteColor];
  }
  if ([value isEqualToString:@"black"]) {
    return [UIColor blackColor];
  }
  if ([value hasPrefix:@"#"]) {
    NSString *hex = [value substringFromIndex:1];
    if (hex.length == 3) {
      NSMutableString *expanded = [NSMutableString string];
      for (NSUInteger i = 0; i < 3; i++) {
        NSString *digit = [hex substringWithRange:NSMakeRange(i, 1)];
        [expanded appendFormat:@"%@%@", digit, digit];
      }
      hex = expanded;
    }
    if (hex.length != 6 && hex.length != 8) {
      return nil;
    }
    unsigned long long bits = 0;
    if (![[NSScanner scannerWithString:hex] scanHexLongLong:&bits]) {
      return nil;
    }
    CGFloat alpha = hex.length == 8 ? (bits & 0xff) / 255.0 : 1.0;
    if (hex.length == 8) {
      bits >>= 8;
    }
    return [UIColor colorWithRed:((bits >> 16) & 0xff) / 255.0 green:((bits >> 8) & 0xff) / 255.0 blue:(bits & 0xff) / 255.0 alpha:alpha];
  }
  if ([value hasPrefix:@"rgb"]) {
    NSRange open = [value rangeOfString:@"("];
    NSRange close = [value rangeOfString:@")"];
    if (open.location == NSNotFound || close.location == NSNotFound || close.location <= open.location) {
      return nil;
    }
    NSArray<NSString *> *parts = [[value substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)] componentsSeparatedByString:@","];
    if (parts.count < 3) {
      return nil;
    }
    CGFloat alpha = parts.count > 3 ? parts[3].doubleValue : 1.0;
    return [UIColor colorWithRed:parts[0].doubleValue / 255.0 green:parts[1].doubleValue / 255.0 blue:parts[2].doubleValue / 255.0 alpha:alpha];
  }
  return nil;
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
@property (nonatomic, assign) BOOL moved;
@property (nonatomic, assign) NSUInteger touchSequence;
@end

@implementation RNCPageCurlTouchObserver

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesBegan:touches withEvent:event];
  self.startPoint = [touches.anyObject locationInView:self.view];
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
  CGPoint point = [touches.anyObject locationInView:self.view];
  if (fabs(point.x - self.startPoint.x) > 8 || fabs(point.y - self.startPoint.y) > 8) {
    self.moved = YES;
  }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesEnded:touches withEvent:event];
  if (self.onTouchesEnded) {
    self.onTouchesEnded();
  }
  self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
  [super touchesCancelled:touches withEvent:event];
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
@property (nonatomic, strong, nullable) UIImage *image;
@property (nonatomic, strong, nullable) id<MTLTexture> texture;
// absent = there is no page in this direction at all (start/end of the book); an empty
// non-absent slot curls onto blank paper that the next bake fills in
@property (nonatomic, assign) BOOL absent;
@end

@implementation RNCPageCurlSlot
@end

@interface RNCWebViewPageCurl () <UIGestureRecognizerDelegate>
@end

@implementation RNCWebViewPageCurl {
  __weak UIView *_hostView;
  __weak WKWebView *_webView;
  RNCPageCurlRenderer *_renderer;
  NSMutableDictionary<NSString *, RNCPageCurlSlot *> *_slots;
  UIPanGestureRecognizer *_pan;
  RNCPageCurlTouchObserver *_touchObserver;
  UIColor *_adoptedPaper;
  NSDictionary<NSString *, NSNumber *> *_tuningValues;
  BOOL _enabled;
  BOOL _spread;
  BOOL _transitionInFlight;
  BOOL _edgeEmitted;
  // curls are allowed only between a finished bake cycle and the next page change
  BOOL _ready;
  // a bake cycle is moving the webview under the renderer
  BOOL _cycleRunning;
  // the renderer must stay visible: a cycle is running, or a turn crossed the chunk edge
  // and the settle that follows will rebake
  BOOL _coverHeld;
  // the manager is moving the webview itself; nothing unlocks before its settle
  BOOL _awaitingSettle;
  BOOL _lockedByTap;
  NSDictionary *_pendingSettle;
  // the settled page; pages count from 0 inside the chunk
  NSInteger _page;
  NSInteger _totalPages;
  NSInteger _chunkIndex;
  BOOL _isLastChunk;
  CGSize _lastSize;
  // the turn in flight: the sheet curls from its right edge in local coordinates, S is where
  // the drag started on that edge and F is where the folded-over corner sits now
  NSString *_turnDirection;
  CGRect _turnSheetRect;
  // the grabbed point, the folded-over point that tracks the finger, and where it sits at rest
  CGPoint _turnStart;
  CGPoint _turnFinger;
  CGPoint _turnRest;
  // the touch-down in sheet-local coordinates; the finger is tracked relative to it, since the grab
  // point may have been moved out from the spine
  CGPoint _turnTouchDown;
  CGFloat _turnRadiusMax;
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
    }
  }
  return self;
}

#pragma mark - colors

- (void)setPaperColor:(NSString *)paperColor
{
  _paperColor = [paperColor copy];
  [self applyColors];
}

- (void)setBackColor:(NSString *)backColor
{
  _backColor = [backColor copy];
  [self applyColors];
}

- (void)setShadowColor:(NSString *)shadowColor
{
  _shadowColor = [shadowColor copy];
  [self applyColors];
}

- (void)setShadowOpacity:(NSNumber *)shadowOpacity
{
  _shadowOpacity = shadowOpacity;
  [self applyColors];
}

- (void)setHighlightColor:(NSString *)highlightColor
{
  _highlightColor = [highlightColor copy];
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
      NSLog(@"[page-curl] tuning ignored: not a JSON object (%@)", error);
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
  RNCPageCurlShading shading = {
    (float)[self tune:@"castWidthFloor"], (float)[self tune:@"castWidthPerRadius"], (float)[self tune:@"castStrengthFloor"],
    (float)[self tune:@"castSoftness"], (float)[self tune:@"aheadNear"], (float)[self tune:@"aheadFar"], (float)[self tune:@"bendDarken"],
    (float)[self tune:@"crestPosition"], (float)[self tune:@"crestWidth"], (float)[self tune:@"riseScale"],
    (float)[self tune:@"aheadStrength"], (float)[self tune:@"tightFade"], (float)[self tune:@"backShowThrough"],
  };
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
  NSLog(@"[page-curl] tuning:%@", summary);
  if (!_renderer.hidden) {
    [_renderer setNeedsDisplay];
  }
}

- (UIColor *)paper
{
  UIColor *paper = _paperColor != nil ? RNCPageCurlColorFromCSS(_paperColor) : nil;
  return paper ?: _adoptedPaper ?: [UIColor whiteColor];
}

- (void)applyColors
{
  if (_renderer == nil) {
    return;
  }
  UIColor *paper = [self paper];
  UIColor *back = _backColor != nil ? RNCPageCurlColorFromCSS(_backColor) : nil;
  UIColor *shadow = _shadowColor != nil ? RNCPageCurlColorFromCSS(_shadowColor) : nil;
  UIColor *highlight = _highlightColor != nil ? RNCPageCurlColorFromCSS(_highlightColor) : nil;
  _renderer.paperColor = paper;
  _renderer.backColor = back ?: RNCPageCurlFadedPaper(paper);
  _renderer.shadowColor = shadow ?: [UIColor blackColor];
  _renderer.shadowOpacity = _shadowOpacity != nil ? _shadowOpacity.doubleValue : 0.35;
  _renderer.highlightColor = highlight ?: [UIColor whiteColor];
  _renderer.highlightOpacity = _highlightOpacity != nil ? _highlightOpacity.doubleValue : 0.2;
  NSLog(@"[page-curl] colors paper=%@ back=%@ shadow=%@@%.2f highlight=%@@%.2f", _renderer.paperColor, _renderer.backColor,
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
  NSLog(@"[page-curl] emit type=%@ direction=%@ detail=%@", type, direction, detail);
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
  NSLog(@"[page-curl] setEnabled %d (was %d) host=%@ web=%@", enabled, _enabled, _hostView, _webView);
  if (enabled == _enabled) {
    return;
  }
  if (!enabled) {
    [self teardown];
    return;
  }
  UIView *host = _hostView;
  if (host == nil || _webView == nil) {
    NSLog(@"[page-curl] cannot enable: host or webview missing");
    return;
  }
  _enabled = YES;
  _spread = [self.spine isEqualToString:@"middle"];
  NSLog(@"[page-curl] spine prop=%@ -> spread=%d", self.spine, _spread);

  _renderer = [[RNCPageCurlRenderer alloc] initWithFrame:host.bounds];
  _renderer.hidden = YES;
  [host addSubview:_renderer];
  [self applyColors];
  [self applyTuning];
  [self showCover];

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
    NSLog(@"[page-curl] touches began; ready=%d", strongSelf->_ready);
    // a new touch supersedes the previous tap; its own touch end decides again
    strongSelf->_lockedByTap = NO;
    [strongSelf makeWebPansYieldToCurl];
    [strongSelf emit:@"touch" direction:nil detail:nil];
  };
  _touchObserver.onTouchesEnded = ^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    BOOL moved = strongSelf->_touchObserver.moved;
    NSLog(@"[page-curl] touches ended; moved=%d inFlight=%d ready=%d", moved, strongSelf->_transitionInFlight, strongSelf->_ready);
    if (!moved && !strongSelf->_transitionInFlight) {
      // a margin tap turns the page in the webview; stay locked until the manager reports
      // either a settle or a touch end without a page change
      strongSelf->_lockedByTap = YES;
      [strongSelf lock:@"tap"];
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
      NSLog(@"[page-curl] held still for 350ms; releasing the curl pan for this touch");
      strongSelf->_pan.enabled = NO;
      strongSelf->_pan.enabled = YES;
      [strongSelf hideIfIdle];
    }
  };
  [host addGestureRecognizer:_touchObserver];

  _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
  _pan.maximumNumberOfTouches = 1;
  _pan.delegate = self;
  [host addGestureRecognizer:_pan];
  NSLog(@"[page-curl] attached pan %@ to host", _pan);
  [self makeWebPansYieldToCurl];
}

// While the curl is on the reader must never scroll by touch: every scroll view inside the webview
// (the document's and WebKit's per-overflow-element ones, which it recreates as chunks load) has
// user scrolling turned off, and the remaining pan and long-press recognizers wait for the curl pan.
// Programmatic scrolling by the manager is unaffected. Rescanned at every touch-down. None of this
// is undone: the host rebuilds the webview when it switches the curl off.
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
  NSLog(@"[page-curl] web scrolling off: %lu scroll views changed, %lu recognizers yield to the curl pan",
        (unsigned long)scrollViews, (unsigned long)recognizers);
}

- (void)setSpine:(NSString *)spine
{
  if ([_spine isEqualToString:spine] || (_spine == nil && spine == nil)) {
    return;
  }
  _spine = [spine copy];
  NSLog(@"[page-curl] spine changed to %@ (enabled=%d)", spine, _enabled);
  if (_enabled) {
    [self teardown];
    [self setEnabled:YES];
    [self requestRebake:@"spine change"];
  }
}

// bakes no longer match the page; the manager settles again once the page has painted
- (void)requestRebake:(NSString *)reason
{
  NSLog(@"[page-curl] rebake requested (%@)", reason);
  [self lock:reason];
  [_webView evaluateJavaScript:@"window.nativePageCurl && window.nativePageCurl.invalidate(); 0;"
             completionHandler:^(id result, NSError *error) {
    if (error != nil) {
      NSLog(@"[page-curl] invalidate bridge error=%@", error);
    }
  }];
}

- (void)teardown
{
  NSLog(@"[page-curl] teardown");
  _enabled = NO;
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
  _transitionInFlight = NO;
  _turnDirection = nil;
  _edgeEmitted = NO;
  _ready = NO;
  _cycleRunning = NO;
  _coverHeld = NO;
  _awaitingSettle = NO;
  _lockedByTap = NO;
  _pendingSettle = nil;
}

- (void)layoutWithBounds:(CGRect)bounds
{
  if (_renderer == nil) {
    return;
  }
  _renderer.frame = bounds;
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
  NSLog(@"[page-curl] rotated slots toward %@", direction);
}

- (void)assignImage:(UIImage *)image toSlot:(NSString *)name
{
  RNCPageCurlSlot *slot = [self slot:name];
  slot.image = image;
  slot.texture = image != nil ? [_renderer textureFromImage:image] : nil;
}

- (void)clearSlot:(NSString *)name
{
  NSLog(@"[page-curl] clear slot=%@ (absent)", name);
  [self assignImage:nil toSlot:name];
  [self slot:name].absent = YES;
}

- (void)blankSlot:(NSString *)name
{
  NSLog(@"[page-curl] blank slot=%@ (page exists, not baked)", name);
  [self assignImage:nil toSlot:name];
  [self slot:name].absent = NO;
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
  [_renderer renderNow];
}

// pages of the turn toward `direction`: what lies underneath, the sheet and what is on its back
- (void)showTurnScene:(NSString *)direction
{
  BOOL next = [direction isEqualToString:RNCPageCurlSlotNext];
  RNCPageCurlSlot *current = [self slot:RNCPageCurlSlotCurrent];
  RNCPageCurlSlot *target = [self slot:direction];
  if (!_spread) {
    // one sheet hinged at the left edge for both directions: a turn back unfolds the previous page
    // from over that same edge, it is not a mirrored right-hand sheet
    _renderer.mirrored = NO;
    if (next) {
      _renderer.underPages = @[[RNCPageCurlPage pageWithTexture:target.texture rect:_renderer.bounds texRect:[self fullTexRect]]];
      _renderer.sheet = [RNCPageCurlPage pageWithTexture:current.texture rect:_renderer.bounds texRect:[self fullTexRect]];
    } else {
      _renderer.underPages = @[[RNCPageCurlPage pageWithTexture:current.texture rect:_renderer.bounds texRect:[self fullTexRect]]];
      _renderer.sheet = [RNCPageCurlPage pageWithTexture:target.texture rect:_renderer.bounds texRect:[self fullTexRect]];
    }
    _renderer.sheetBackTexture = nil;
  } else if (next) {
    _renderer.mirrored = NO;
    _renderer.underPages = @[
      [RNCPageCurlPage pageWithTexture:current.texture rect:[self leftHalf] texRect:[self leftTexRect]],
      [RNCPageCurlPage pageWithTexture:target.texture rect:[self rightHalf] texRect:[self rightTexRect]],
    ];
    _renderer.sheet = [RNCPageCurlPage pageWithTexture:current.texture rect:[self rightHalf] texRect:[self rightTexRect]];
    _renderer.sheetBackTexture = target.texture;
    _renderer.sheetBackTexRect = [self leftTexRect];
  } else {
    _renderer.mirrored = YES;
    _renderer.underPages = @[
      [RNCPageCurlPage pageWithTexture:target.texture rect:[self leftHalf] texRect:[self leftTexRect]],
      [RNCPageCurlPage pageWithTexture:current.texture rect:[self rightHalf] texRect:[self rightTexRect]],
    ];
    _renderer.sheet = [RNCPageCurlPage pageWithTexture:current.texture rect:[self leftHalf] texRect:[self leftTexRect]];
    _renderer.sheetBackTexture = target.texture;
    _renderer.sheetBackTexRect = [self rightTexRect];
  }
  _renderer.curling = YES;
  NSMutableString *scene = [NSMutableString string];
  for (RNCPageCurlPage *page in _renderer.underPages) {
    [scene appendFormat:@" under rect=%@ tex=%@ %@;", NSStringFromCGRect(page.rect), NSStringFromCGRect(page.texRect), page.texture ? @"image" : @"paper"];
  }
  [scene appendFormat:@" sheet rect=%@ tex=%@ %@ back=%@ %@", NSStringFromCGRect(_renderer.sheet.rect), NSStringFromCGRect(_renderer.sheet.texRect),
   _renderer.sheet.texture ? @"image" : @"paper", NSStringFromCGRect(_renderer.sheetBackTexRect), _renderer.sheetBackTexture ? @"image" : @"color"];
  NSLog(@"[page-curl] scene %@ mirrored=%d:%@", direction, _renderer.mirrored, scene);
}

#pragma mark - webview bridge

- (void)snapshotIntoSlot:(NSString *)slot completion:(void (^)(BOOL ok))completion
{
  WKWebView *webView = _webView;
  if (webView == nil) {
    NSLog(@"[page-curl] snapshot slot=%@ failed: webview missing", slot);
    completion(NO);
    return;
  }
  WKSnapshotConfiguration *config = [WKSnapshotConfiguration new];
  config.afterScreenUpdates = YES;
  CFTimeInterval start = CACurrentMediaTime();
  __weak __typeof(self) weakSelf = self;
  [webView takeSnapshotWithConfiguration:config completionHandler:^(UIImage *image, NSError *error) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    double ms = (CACurrentMediaTime() - start) * 1000.0;
    NSLog(@"[page-curl] snapshot slot=%@ took %.1fms image=%@ error=%@", slot, ms, NSStringFromCGSize(image.size), error);
    if (error != nil || image == nil) {
      completion(NO);
      return;
    }
    [strongSelf assignImage:image toSlot:slot];
    [strongSelf slot:slot].absent = NO;
    if ([slot isEqualToString:RNCPageCurlSlotCurrent] && strongSelf->_paperColor == nil) {
      [strongSelf adoptPaperColorFrom:image];
    }
    completion(YES);
  }];
}

// window.nativePageCurl.<fn>(page) in the content frame; jump resolves once the page painted,
// commit once the manager recorded the resting page
- (void)callBridge:(NSString *)fn page:(NSInteger)page completion:(void (^)(BOOL ok))completion
{
  [self callBridge:fn argument:@(page) completion:^(BOOL ok, id result) {
    completion(ok);
  }];
}

- (void)callBridge:(NSString *)fn argument:(id)argument completion:(void (^)(BOOL ok, id result))completion
{
  WKWebView *webView = _webView;
  if (webView == nil) {
    NSLog(@"[page-curl] bridge %@(%@) failed: webview missing", fn, argument);
    completion(NO, nil);
    return;
  }
  NSString *body = [NSString stringWithFormat:
      @"if (!window.nativePageCurl) { throw new Error('nativePageCurl bridge missing'); }"
       "return await window.nativePageCurl.%@(argument);", fn];
  CFTimeInterval start = CACurrentMediaTime();
  [webView callAsyncJavaScript:body
                     arguments:@{@"argument": argument ?: [NSNull null]}
                       inFrame:nil
                inContentWorld:WKContentWorld.pageWorld
             completionHandler:^(id result, NSError *error) {
    double ms = (CACurrentMediaTime() - start) * 1000.0;
    NSLog(@"[page-curl] bridge %@(%@) took %.1fms result=%@ error=%@", fn, argument, ms, result, error);
    completion(error == nil, result);
  }];
}

- (void)setManagerReady
{
  [_webView evaluateJavaScript:@"window.nativePageCurl && window.nativePageCurl.setReady(true); 0;"
             completionHandler:^(id result, NSError *error) {
    if (error != nil) {
      NSLog(@"[page-curl] setReady bridge error=%@", error);
    }
  }];
}

#pragma mark - bake cycles

- (RNCPageCurlStep)stepSnapshot:(NSString *)slot
{
  __weak __typeof(self) weakSelf = self;
  return ^(void (^done)(BOOL)) {
    [weakSelf snapshotIntoSlot:slot completion:^(BOOL ok) {
      // a failed neighbor bake curls onto blank paper; a failed current bake has no cover to show
      if (!ok && ![slot isEqualToString:RNCPageCurlSlotCurrent]) {
        [weakSelf blankSlot:slot];
        done(YES);
        return;
      }
      done(ok);
    }];
  };
}

- (RNCPageCurlStep)stepBridge:(NSString *)fn page:(NSInteger)page
{
  __weak __typeof(self) weakSelf = self;
  return ^(void (^done)(BOOL)) {
    [weakSelf callBridge:fn page:page completion:done];
  };
}

- (RNCPageCurlStep)stepBlock:(void (^)(void))block
{
  return ^(void (^done)(BOOL)) {
    block();
    done(YES);
  };
}

- (void)runSteps:(NSArray<RNCPageCurlStep> *)steps index:(NSUInteger)index completion:(void (^)(BOOL ok))completion
{
  if (!_enabled) {
    NSLog(@"[page-curl] cycle dropped at step %lu: disabled", (unsigned long)index);
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
    if (!ok) {
      completion(NO);
      return;
    }
    [strongSelf runSteps:steps index:index + 1 completion:completion];
  });
}

// the slot on the far side of the target page: bake it, bake the neighboring chunk's edge page
// through the manager's own chunk switch (blank paper if that is refused), or nothing at the
// ends of the book
- (void)addNeighborStepsForPage:(NSInteger)page direction:(NSString *)direction to:(NSMutableArray<RNCPageCurlStep> *)steps
{
  BOOL next = [direction isEqualToString:RNCPageCurlSlotNext];
  NSInteger neighbor = next ? page + 1 : page - 1;
  BOOL exists = next ? page < _totalPages : page > 0;
  BOOL beyondChunk = next ? !_isLastChunk : _chunkIndex > 0;
  if (exists) {
    [steps addObject:[self stepBridge:@"jump" page:neighbor]];
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
  [steps addObject:^(void (^done)(BOOL)) {
    [weakSelf callBridge:@"peek" argument:direction completion:^(BOOL ok, id result) {
      __strong __typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf == nil) {
        return;
      }
      if (!ok || ![result isKindOfClass:[NSNumber class]] || ![result boolValue]) {
        NSLog(@"[page-curl] peek %@ refused; curling onto blank paper", direction);
        [strongSelf blankSlot:direction];
        done(YES);
        return;
      }
      [strongSelf snapshotIntoSlot:direction completion:^(BOOL snapped) {
        if (!snapped) {
          [weakSelf blankSlot:direction];
        }
        done(YES);
      }];
    }];
  }];
  [steps addObject:^(void (^done)(BOOL)) {
    [weakSelf callBridge:@"unpeek" argument:nil completion:^(BOOL ok, id result) {
      done(ok);
    }];
  }];
}

- (void)finishCycle:(BOOL)ok reason:(NSString *)reason
{
  _cycleRunning = NO;
  _coverHeld = NO;
  _renderer.hidden = YES;
  if (!ok) {
    NSLog(@"[page-curl] cycle failed (%@); locked until the next settle", reason);
    _ready = NO;
    return;
  }
  [self unlock:reason];
  [self runPendingSettle];
}

// every slot from scratch: the reader is on a page native did not curl to
- (void)runFullCycleWithSettle:(NSDictionary *)settle
{
  _pendingSettle = nil;
  _page = [settle[@"page"] integerValue];
  _totalPages = [settle[@"totalPages"] integerValue];
  _chunkIndex = [settle[@"chunkIndex"] integerValue];
  _isLastChunk = [settle[@"isLastChunk"] boolValue];
  _cycleRunning = YES;
  _coverHeld = YES;
  _awaitingSettle = NO;
  _lockedByTap = NO;
  _ready = NO;
  CFTimeInterval start = CACurrentMediaTime();
  NSLog(@"[page-curl] full cycle start page=%ld/%ld chunk=%ld last=%d", (long)_page, (long)_totalPages, (long)_chunkIndex, _isLastChunk);

  __weak __typeof(self) weakSelf = self;
  NSMutableArray<RNCPageCurlStep> *steps = [NSMutableArray array];
  [steps addObject:[self stepSnapshot:RNCPageCurlSlotCurrent]];
  [steps addObject:[self stepBlock:^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    [strongSelf showCover];
    strongSelf->_renderer.hidden = NO;
  }]];
  BOOL moved = _page < _totalPages || _page > 0;
  [self addNeighborStepsForPage:_page direction:RNCPageCurlSlotNext to:steps];
  [self addNeighborStepsForPage:_page direction:RNCPageCurlSlotPrevious to:steps];
  if (moved) {
    [steps addObject:[self stepBridge:@"jump" page:_page]];
  }
  [self runSteps:steps index:0 completion:^(BOOL ok) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    NSLog(@"[page-curl] full cycle %@ in %.1fms", ok ? @"done" : @"FAILED", (CACurrentMediaTime() - start) * 1000.0);
    if (ok) {
      [strongSelf setManagerReady];
    }
    [strongSelf finishCycle:ok reason:@"full cycle"];
  }];
}

// after a completed curl: the bakes already on screen are kept, only the far neighbor of the
// new page is fetched, then the webview is parked on the new page and the manager told
- (void)finishTurnToward:(NSString *)direction
{
  BOOL next = [direction isEqualToString:RNCPageCurlSlotNext];
  NSInteger target = next ? _page + 1 : _page - 1;
  _ready = NO;
  _lockedByTap = NO;
  if (target < 0 || target > _totalPages) {
    // curled onto blank paper: the manager runs its chunk transition and settles when done
    NSLog(@"[page-curl] turn crossed the chunk edge to page %ld; waiting for the settle", (long)target);
    _coverHeld = YES;
    _awaitingSettle = YES;
    __weak __typeof(self) weakSelf = self;
    [self callBridge:@"commit" page:target completion:^(BOOL ok) {
      if (!ok) {
        [weakSelf finishCycle:NO reason:@"edge commit"];
      }
    }];
    return;
  }
  _page = target;
  _cycleRunning = YES;
  _coverHeld = YES;
  CFTimeInterval start = CACurrentMediaTime();
  NSLog(@"[page-curl] turn cycle start page=%ld/%ld", (long)_page, (long)_totalPages);

  NSMutableArray<RNCPageCurlStep> *steps = [NSMutableArray array];
  [self addNeighborStepsForPage:_page direction:direction to:steps];
  [steps addObject:[self stepBridge:@"jump" page:_page]];
  [steps addObject:[self stepBridge:@"commit" page:_page]];
  __weak __typeof(self) weakSelf = self;
  [self runSteps:steps index:0 completion:^(BOOL ok) {
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil) {
      return;
    }
    NSLog(@"[page-curl] turn cycle %@ in %.1fms", ok ? @"done" : @"FAILED", (CACurrentMediaTime() - start) * 1000.0);
    [strongSelf finishCycle:ok reason:@"turn cycle"];
  }];
}

- (void)runPendingSettle
{
  NSDictionary *pending = _pendingSettle;
  if (pending == nil || _cycleRunning || _transitionInFlight || [self panActive]) {
    return;
  }
  NSLog(@"[page-curl] running the deferred settle");
  [self runFullCycleWithSettle:pending];
}

#pragma mark - messages from the content frame

- (void)handleMessage:(NSDictionary *)message
{
  NSString *type = message[@"type"];
  NSLog(@"[page-curl] message %@ (ready=%d cycle=%d cover=%d awaiting=%d tapLock=%d)", message, _ready, _cycleRunning, _coverHeld, _awaitingSettle, _lockedByTap);
  if (_renderer == nil) {
    return;
  }
  if ([type isEqualToString:@"settled"]) {
    [self emit:@"settled" direction:nil detail:[NSString stringWithFormat:@"page %@/%@ chunk %@", message[@"page"], message[@"totalPages"], message[@"chunkIndex"]]];
    _ready = NO;
    if (_cycleRunning || _transitionInFlight || [self panActive]) {
      NSLog(@"[page-curl] settle deferred: busy");
      _pendingSettle = message;
      return;
    }
    [self runFullCycleWithSettle:message];
    return;
  }
  if ([type isEqualToString:@"unsettled"]) {
    _awaitingSettle = YES;
    _lockedByTap = NO;
    [self lock:@"unsettled"];
    return;
  }
  if ([type isEqualToString:@"chunkFade"]) {
    // the manager has hidden the old chunk and will fade the new one in; after a turn onto blank
    // paper the cover is dropped so that fade shows, and the rebake after the settle covers again.
    // A turn onto the real edge page keeps its cover: the rebake will match it pixel for pixel.
    if (_awaitingSettle && !_cycleRunning && !_transitionInFlight && [self slot:RNCPageCurlSlotCurrent].texture == nil) {
      NSLog(@"[page-curl] chunk fade: uncovering the webview");
      _coverHeld = NO;
      _renderer.hidden = YES;
    }
    return;
  }
  if ([type isEqualToString:@"touchEnd"]) {
    if (!_lockedByTap) {
      return;
    }
    _lockedByTap = NO;
    if (_awaitingSettle || _cycleRunning || _coverHeld || _transitionInFlight || [self panActive]) {
      NSLog(@"[page-curl] touch end while busy; staying locked");
      return;
    }
    [self unlock:@"tap without a page change"];
    return;
  }
  NSLog(@"[page-curl] unknown message type %@", type);
}

#pragma mark - locking

- (BOOL)panActive
{
  return _pan.state == UIGestureRecognizerStateBegan || _pan.state == UIGestureRecognizerStateChanged;
}

- (void)hideIfIdle
{
  if (_coverHeld || _transitionInFlight || [self panActive]) {
    return;
  }
  _renderer.hidden = YES;
}

- (void)lock:(NSString *)reason
{
  if (_ready) {
    NSLog(@"[page-curl] ready -> 0 (%@)", reason);
  }
  _ready = NO;
  [self hideIfIdle];
}

- (void)unlock:(NSString *)reason
{
  if (!_ready) {
    NSLog(@"[page-curl] ready -> 1 (%@)", reason);
  }
  _ready = YES;
  [self emit:@"ready" direction:nil detail:reason];
  [self beginTurnFromWaitingPan];
}

#pragma mark - gestures

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
  if (gestureRecognizer != _pan) {
    return YES;
  }
  // the curl pan claims every drag while the curl is on, so WebKit's pans never scroll the page
  // themselves; if the bakes are still being made the turn starts when they are ready
  NSLog(@"[page-curl] pan should begin? ready=%d inFlight=%d", _ready, _transitionInFlight);
  return !_transitionInFlight;
}

// a pan that began before the bakes were ready: start its turn now, from the original touch-down
- (void)beginTurnFromWaitingPan
{
  if (![self panActive] || _turnDirection != nil || _transitionInFlight || _turnDeclined) {
    return;
  }
  CGPoint touchDown = _touchObserver.startPoint;
  CGPoint location = [_pan locationInView:_hostView];
  CGFloat dx = location.x - touchDown.x;
  if (dx == 0) {
    return;
  }
  NSLog(@"[page-curl] bakes ready during a waiting pan; starting its turn (dx=%.0f)", dx);
  [self beginTurn:dx < 0 ? RNCPageCurlSlotNext : RNCPageCurlSlotPrevious from:touchDown];
  _turnDeclined = _turnDirection == nil;
  if (_turnDirection != nil) {
    [self moveTurnTo:location];
  }
}

- (void)onPan:(UIPanGestureRecognizer *)pan
{
  CGPoint translation = [pan translationInView:_hostView];
  CGPoint location = [pan locationInView:_hostView];
  NSLog(@"[page-curl] pan state=%ld location=%.1f,%.1f translation=%.1f,%.1f touchDown=%@ inFlight=%d turn=%@", (long)pan.state, location.x, location.y,
        translation.x, translation.y, NSStringFromCGPoint(_touchObserver.startPoint), _transitionInFlight, _turnDirection);
  BOOL moving = pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged;
  // the pan's translation restarts from zero where recognition began; the observer has the touch-down
  CGPoint touchDown = _touchObserver.startPoint;
  CGFloat dx = location.x - touchDown.x;
  if (_turnDirection == nil && moving && dx != 0 && !_transitionInFlight && !_turnDeclined) {
    if (!_ready) {
      if (pan.state == UIGestureRecognizerStateBegan) {
        NSLog(@"[page-curl] pan began before the bakes are ready; holding the drag until they are");
      }
      return;
    }
    NSString *direction = dx < 0 ? RNCPageCurlSlotNext : RNCPageCurlSlotPrevious;
    [self beginTurn:direction from:touchDown];
    _turnDeclined = _turnDirection == nil;
  }
  if (_turnDirection == nil) {
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
      _turnDeclined = NO;
      NSLog(@"[page-curl] pan ended without a turn (ready=%d)", _ready);
      [self hideIfIdle];
      [self runPendingSettle];
    }
    return;
  }
  if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
    [self moveTurnTo:location];
    return;
  }
  if (pan.state == UIGestureRecognizerStateEnded) {
    [self releaseTurnWithVelocity:[pan velocityInView:_hostView]];
    return;
  }
  if (pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
    [self releaseTurnWithVelocity:CGPointZero];
  }
}

#pragma mark - turns

- (void)beginTurn:(NSString *)direction from:(CGPoint)start
{
  RNCPageCurlSlot *target = [self slot:direction];
  if (target.absent) {
    NSLog(@"[page-curl] no page toward %@; no curl", direction);
    return;
  }
  if (target.texture == nil && !_edgeEmitted) {
    _edgeEmitted = YES;
    [self emit:@"edge" direction:direction detail:nil];
  }
  BOOL next = [direction isEqualToString:RNCPageCurlSlotNext];
  _turnDirection = direction;
  _turnReversed = !next && !_spread;
  _transitionInFlight = YES;
  // locked for the whole turn; a cancelled turn hands the still-valid bakes back
  _ready = NO;
  [self showTurnScene:direction];
  _turnSheetRect = _renderer.sheet.rect;
  CGFloat width = _turnSheetRect.size.width;
  CGFloat height = _turnSheetRect.size.height;
  _turnRadiusMax = MIN([self tune:@"radiusMax"], width * [self tune:@"radiusFraction"]);
  _renderer.curlRadiusMax = _turnRadiusMax;
  // the sheet is always grabbed at its outer edge on the touch's row, wherever the touch lands, and
  // that edge moves exactly as far as the finger does
  _turnStart = CGPointMake(width, MIN(MAX(start.y - _turnSheetRect.origin.y, 0), height));
  _turnRest = _turnReversed ? [self turnedFinger] : _turnStart;
  _turnTouchDown = CGPointMake([self localXFor:start.x], start.y - _turnSheetRect.origin.y);
  _renderer.curlStart = _turnStart;
  NSLog(@"[page-curl] turn %@ begins at %@ grab=%@ sheet=%@ mirrored=%d reversed=%d radiusMax=%.0f", direction, NSStringFromCGPoint(start),
        NSStringFromCGPoint(_turnStart), NSStringFromCGRect(_turnSheetRect), _renderer.mirrored, _turnReversed, _turnRadiusMax);
  [self applyFinger:_turnRest];
  // the layer would otherwise show whatever it drew last for a frame
  [_renderer renderNow];
  _renderer.hidden = NO;
}

- (CGFloat)localXFor:(CGFloat)x
{
  return _renderer.mirrored ? CGRectGetMaxX(_turnSheetRect) - x : x - _turnSheetRect.origin.x;
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
  CGPoint finger = CGPointMake(_turnRest.x + local.x - _turnTouchDown.x, _turnRest.y + local.y - _turnTouchDown.y);
  finger.x = MIN(MAX(finger.x, [self turnedFinger].x), _turnStart.x);
  finger.y = MIN(MAX(finger.y, 0), _turnSheetRect.size.height);
  [self applyFinger:finger];
}

- (void)applyFinger:(CGPoint)finger
{
  CGPoint asked = finger;
  CGFloat dx = MAX(_turnStart.x - finger.x, 0);
  CGFloat dy = _turnStart.y - finger.y;
  // the fold's tilt follows the vertical offset against the horizontal drag plus a softness constant, so
  // a small vertical move tilts it a little instead of flipping it; the fold advances by the drag's
  // projection on that direction, so a vertical wiggle barely moves it
  CGFloat soft = MAX([self tune:@"tiltSoftness"], 0);
  CGFloat ex = dx + soft;
  CGFloat norm = sqrt(ex * ex + dy * dy);
  CGFloat nx = 1, ny = 0;
  if (norm > 0.5) {
    nx = ex / norm;
    ny = dy / norm;
  }
  CGFloat distance = MAX(dx * nx + dy * ny, 0);
  // the sheet is hinged along the whole spine (local x = 0, y in 0..h). The fold line sits
  // (distance + pi R) / 2 behind the grab point along n; it must leave every spine point on the
  // flat side, so the tilt gives way first, then the bend flattens, then the finger is held back.
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
  _renderer.curlProgress = MIN(MAX((_turnStart.x - foldX) / MAX(_turnStart.x, 1), 0), 1);
  NSLog(@"[page-curl] finger %.1f,%.1f (asked %.1f,%.1f grab=%.1f,%.1f distance=%.1f room=%.1f foldOffset=%.1f foldX=%.1f) -> %@", finger.x, finger.y,
        asked.x, asked.y, _turnStart.x, _turnStart.y, distance, room, foldOffset, foldX, [_renderer curlDescription]);
  [_renderer setNeedsDisplay];
}

// 0 at the start of the turn, 1 when the page has fully turned
- (CGFloat)turnProgress
{
  CGFloat progress = _renderer.curlProgress;
  return _turnReversed ? 1 - progress : progress;
}

- (void)releaseTurnWithVelocity:(CGPoint)velocity
{
  BOOL next = [_turnDirection isEqualToString:RNCPageCurlSlotNext];
  CGFloat toward = next ? -velocity.x : velocity.x;
  CGFloat progress = [self turnProgress];
  // a drag past completeFraction of the turn, or a flick faster than flickVelocity, completes it
  BOOL completes = fabs(velocity.x) > [self tune:@"flickVelocity"] ? toward > 0 : progress > [self tune:@"completeFraction"];
  CGFloat speedMin = [self tune:@"speedMin"];
  CGFloat speed = MIN([self tune:@"speedMax"], MAX(speedMin, speedMin + fabs(velocity.x) / 3000.0));
  CGFloat remaining = completes ? 1 - progress : progress;
  CGFloat duration = ([self tune:@"durationBase"] + [self tune:@"durationPerRemaining"] * remaining) / speed;
  CGPoint flat = _turnStart;
  CGPoint turned = [self turnedFinger];
  BOOL endsTurned = completes != _turnReversed;
  NSLog(@"[page-curl] release velocity=%.0f progress=%.2f -> %@ in %.0fms", velocity.x, progress, completes ? @"complete" : @"cancel", duration * 1000);
  [self animateFingerTo:endsTurned ? turned : flat duration:duration completes:completes];
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
    [self finishTransitionCompleted:completes];
  }
}

- (void)stopAnimation
{
  [_animation invalidate];
  _animation = nil;
}

- (void)finishTransitionCompleted:(BOOL)completed
{
  NSString *direction = _turnDirection;
  _turnDirection = nil;
  _transitionInFlight = NO;
  _edgeEmitted = NO;
  NSLog(@"[page-curl] turn %@ finished completed=%d", direction, completed);
  if (!completed) {
    [self showCover];
    [self hideIfIdle];
    [self emit:@"cancel" direction:nil detail:nil];
    if (_pendingSettle != nil) {
      [self runPendingSettle];
    } else if (!_awaitingSettle && !_coverHeld) {
      [self unlock:@"curl cancelled"];
    }
    return;
  }
  [self emit:@"turn" direction:direction detail:[NSString stringWithFormat:@"from page %ld", (long)_page]];
  [self rotateSlotsToward:direction];
  [self showCover];
  [self finishTurnToward:direction];
}

@end
