#import "RNCWebViewPageCurl.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>

static NSString *const RNCPageCurlSlotCurrent = @"current";
static NSString *const RNCPageCurlSlotPrevious = @"previous";
static NSString *const RNCPageCurlSlotNext = @"next";

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

// Never recognizes; only reports raw touch begin/end so the page controller's view can be
// made visible before its pan recognizer evaluates the touch (the curl will not start on a hidden view).
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

@interface RNCPageCurlImageViewController : UIViewController
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, copy) NSString *slot;
@property (nonatomic, assign) NSInteger half; // 0 = whole sheet or left half, 1 = right half
// absent = there is no page in this direction at all (start/end of the book); an empty
// non-absent slot curls onto a blank paper-colored page that the next bake fills in
@property (nonatomic, assign) BOOL absent;
// the reverse side of a sheet: paper only, shown while the sheet is mid-curl
@property (nonatomic, assign) BOOL back;
@end

@implementation RNCPageCurlImageViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];
  _imageView = [[UIImageView alloc] initWithFrame:self.view.bounds];
  _imageView.contentMode = UIViewContentModeScaleToFill;
  _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:_imageView];
}

@end

@interface RNCWebViewPageCurl () <UIPageViewControllerDataSource, UIPageViewControllerDelegate>
@end

@implementation RNCWebViewPageCurl {
  __weak UIView *_hostView;
  __weak WKWebView *_webView;
  UIPageViewController *_pageController;
  // ordered previous(L,R) current(L,R) next(L,R); one controller per slot when not a spread
  NSArray<RNCPageCurlImageViewController *> *_orderedControllers;
  NSMutableDictionary<NSString *, NSArray<RNCPageCurlImageViewController *> *> *_slotControllers;
  // single-sheet mode only: one back face per slot, interleaved after its front in the order
  NSArray<RNCPageCurlImageViewController *> *_backControllers;
  UIPanGestureRecognizer *_pan;
  RNCPageCurlTouchObserver *_touchObserver;
  BOOL _enabled;
  BOOL _spread;
  BOOL _transitionInFlight;
  BOOL _edgeEmitted;
  // curls are allowed only between a finished bake cycle and the next page change
  BOOL _ready;
  // a bake cycle is moving the webview under the controller
  BOOL _cycleRunning;
  // the controller must stay visible: a cycle is running, or a turn crossed the chunk edge
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
  BOOL _dumpedCurlLayers;
}

- (instancetype)initWithHostView:(UIView *)hostView webView:(WKWebView *)webView
{
  if ((self = [super init])) {
    _hostView = hostView;
    _webView = webView;
  }
  return self;
}

- (RNCPageCurlImageViewController *)makeImageViewController:(NSString *)slot half:(NSInteger)half
{
  RNCPageCurlImageViewController *vc = [RNCPageCurlImageViewController new];
  vc.slot = slot;
  vc.half = half;
  [vc loadViewIfNeeded];
  return vc;
}

- (void)buildControllersForSpread:(BOOL)spread
{
  _spread = spread;
  NSMutableDictionary *bySlot = [NSMutableDictionary dictionary];
  for (NSString *slot in @[RNCPageCurlSlotPrevious, RNCPageCurlSlotCurrent, RNCPageCurlSlotNext]) {
    NSMutableArray *vcs = [NSMutableArray array];
    [vcs addObject:[self makeImageViewController:slot half:0]];
    if (spread) {
      [vcs addObject:[self makeImageViewController:slot half:1]];
    }
    bySlot[slot] = vcs;
  }
  _slotControllers = bySlot;
  if (spread) {
    _backControllers = nil;
  } else {
    NSMutableArray *backs = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
      RNCPageCurlImageViewController *vc = [self makeImageViewController:RNCPageCurlSlotCurrent half:0];
      vc.back = YES;
      [backs addObject:vc];
    }
    _backControllers = backs;
  }
  [self relabelSlots];
  [self applyPaperColor];
  NSLog(@"[page-curl] built %lu page controllers (spread=%d)", (unsigned long)_orderedControllers.count, spread);
}

- (void)setPaperColor:(NSString *)paperColor
{
  _paperColor = [paperColor copy];
  [self applyPaperColor];
}

- (void)applyPaperColor
{
  UIColor *paper = _paperColor != nil ? RNCPageCurlColorFromCSS(_paperColor) : nil;
  NSLog(@"[page-curl] paper color %@ -> %@", _paperColor, paper);
  if (paper == nil) {
    return;
  }
  [self paintPaper:paper];
}

// fronts get the paper as is; the back of a sheet is the same paper slightly faded toward the
// opposite extreme so it reads as the reverse side in both light and dark themes
- (void)paintPaper:(UIColor *)paper
{
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [paper getRed:&r green:&g blue:&b alpha:&a];
  CGFloat luma = 0.299 * r + 0.587 * g + 0.114 * b;
  CGFloat toward = luma < 0.5 ? 1.0 : 0.0;
  CGFloat amount = 0.12;
  UIColor *faded = [UIColor colorWithRed:r + (toward - r) * amount green:g + (toward - g) * amount blue:b + (toward - b) * amount alpha:1];
  for (RNCPageCurlImageViewController *vc in _orderedControllers) {
    vc.view.backgroundColor = vc.back ? faded : paper;
  }
}

- (void)relabelSlots
{
  NSMutableArray *ordered = [NSMutableArray array];
  NSUInteger slotIndex = 0;
  for (NSString *slot in @[RNCPageCurlSlotPrevious, RNCPageCurlSlotCurrent, RNCPageCurlSlotNext]) {
    for (RNCPageCurlImageViewController *vc in _slotControllers[slot]) {
      vc.slot = slot;
      [ordered addObject:vc];
    }
    if (_backControllers != nil) {
      RNCPageCurlImageViewController *back = _backControllers[slotIndex];
      back.slot = slot;
      [ordered addObject:back];
    }
    slotIndex += 1;
  }
  _orderedControllers = ordered;
}

// after a turn the displayed controller becomes "current" and the two others rotate with it;
// the slot that fell off the far side is the only one that needs a new bake
- (void)rotateSlotsToward:(NSString *)direction
{
  NSArray *previous = _slotControllers[RNCPageCurlSlotPrevious];
  NSArray *current = _slotControllers[RNCPageCurlSlotCurrent];
  NSArray *next = _slotControllers[RNCPageCurlSlotNext];
  if ([direction isEqualToString:RNCPageCurlSlotNext]) {
    _slotControllers[RNCPageCurlSlotPrevious] = current;
    _slotControllers[RNCPageCurlSlotCurrent] = next;
    _slotControllers[RNCPageCurlSlotNext] = previous;
    [self relabelSlots];
    [self blankSlot:RNCPageCurlSlotNext];
  } else {
    _slotControllers[RNCPageCurlSlotNext] = current;
    _slotControllers[RNCPageCurlSlotCurrent] = previous;
    _slotControllers[RNCPageCurlSlotPrevious] = next;
    [self relabelSlots];
    [self blankSlot:RNCPageCurlSlotPrevious];
  }
  NSLog(@"[page-curl] rotated slots toward %@; shown=%@", direction, [self shownSlot]);
}

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
  BOOL spread = [self.spine isEqualToString:@"middle"];
  NSLog(@"[page-curl] spine prop=%@ -> spread=%d", self.spine, spread);
  [self buildControllersForSpread:spread];

  UIPageViewControllerSpineLocation spine = spread ? UIPageViewControllerSpineLocationMid : UIPageViewControllerSpineLocationMin;
  _pageController = [[UIPageViewController alloc]
      initWithTransitionStyle:UIPageViewControllerTransitionStylePageCurl
        navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                      options:@{UIPageViewControllerOptionSpineLocationKey: @(spine)}];
  _pageController.dataSource = self;
  _pageController.delegate = self;
  // double-sided in both modes: a single sheet's reverse is our own paper-colored face instead
  // of UIKit's white translucent rendering of the front
  _pageController.doubleSided = YES;

  UIResponder *responder = host;
  while (responder != nil && ![responder isKindOfClass:[UIViewController class]]) {
    responder = responder.nextResponder;
  }
  UIViewController *parent = (UIViewController *)responder;
  NSLog(@"[page-curl] parent view controller: %@ spread=%d", parent, spread);
  if (parent != nil) {
    [parent addChildViewController:_pageController];
  }
  _pageController.view.frame = host.bounds;
  _pageController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _pageController.view.hidden = YES;
  _pageController.view.backgroundColor = [UIColor clearColor];
  [host addSubview:_pageController.view];
  if (parent != nil) {
    [_pageController didMoveToParentViewController:parent];
  }
  [self showSlot:RNCPageCurlSlotCurrent];

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
    NSLog(@"[page-curl] touches began; ready=%d (was hidden=%d)", strongSelf->_ready, strongSelf->_pageController.view.hidden);
    // a new touch supersedes the previous tap; its own touch end decides again
    strongSelf->_lockedByTap = NO;
    if (strongSelf->_ready) {
      strongSelf->_pageController.view.hidden = NO;
    }
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

  for (UIGestureRecognizer *recognizer in _pageController.gestureRecognizers) {
    if ([recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
      _pan = (UIPanGestureRecognizer *)recognizer;
      [_pan addTarget:self action:@selector(onPan:)];
      [host addGestureRecognizer:_pan];
      NSLog(@"[page-curl] attached pan %@ to host", _pan);
      [self makeWebPansYieldToCurl];
    } else {
      recognizer.enabled = NO;
      NSLog(@"[page-curl] disabled recognizer %@", recognizer);
    }
  }
}

// WebKit's content view carries several pan recognizers (scroll views per overflow element, plus a
// plain UIPanGestureRecognizer) that race the page controller's pan on horizontal drags. Every one
// of them must wait for the curl pan to fail first.
- (void)makeWebPansYieldToCurl
{
  if (_pan == nil || _webView == nil) {
    return;
  }
  NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:_webView];
  NSUInteger count = 0;
  while (stack.count > 0) {
    UIView *view = stack.lastObject;
    [stack removeLastObject];
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
      BOOL isPan = [recognizer isKindOfClass:[UIPanGestureRecognizer class]];
      BOOL isLongPress = [recognizer isKindOfClass:[UILongPressGestureRecognizer class]];
      if ((isPan || isLongPress) && recognizer != _pan) {
        [recognizer requireGestureRecognizerToFail:_pan];
        count += 1;
      }
    }
    [stack addObjectsFromArray:view.subviews];
  }
  NSLog(@"[page-curl] %lu web pan recognizers now yield to the curl pan", (unsigned long)count);
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
  if (_pan != nil) {
    [_pan removeTarget:self action:@selector(onPan:)];
    [_pan.view removeGestureRecognizer:_pan];
    _pan = nil;
  }
  if (_touchObserver != nil) {
    [_touchObserver.view removeGestureRecognizer:_touchObserver];
    _touchObserver = nil;
  }
  if (_pageController != nil) {
    [_pageController willMoveToParentViewController:nil];
    [_pageController.view removeFromSuperview];
    [_pageController removeFromParentViewController];
    _pageController = nil;
  }
  _transitionInFlight = NO;
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
  if (_pageController == nil) {
    return;
  }
  _pageController.view.frame = bounds;
  BOOL resized = !CGSizeEqualToSize(_lastSize, CGSizeZero) && !CGSizeEqualToSize(_lastSize, bounds.size);
  _lastSize = bounds.size;
  if (resized) {
    [self requestRebake:@"resize"];
  }
}

- (NSArray<RNCPageCurlImageViewController *> *)controllersForSlot:(NSString *)slot
{
  return _slotControllers[slot] ?: _slotControllers[RNCPageCurlSlotCurrent];
}

- (void)showSlot:(NSString *)slot
{
  NSArray *vcs = [self controllersForSlot:slot];
  [_pageController setViewControllers:vcs
                            direction:UIPageViewControllerNavigationDirectionForward
                             animated:NO
                           completion:nil];
}

- (NSString *)shownSlot
{
  RNCPageCurlImageViewController *shown = (RNCPageCurlImageViewController *)_pageController.viewControllers.firstObject;
  return shown.slot ?: RNCPageCurlSlotCurrent;
}

- (BOOL)panActive
{
  return _pan.state == UIGestureRecognizerStateBegan || _pan.state == UIGestureRecognizerStateChanged;
}

- (void)hideIfIdle
{
  if (_coverHeld || _transitionInFlight || [self panActive]) {
    return;
  }
  _pageController.view.hidden = YES;
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
}

- (void)assignImage:(UIImage *)image toSlot:(NSString *)slot
{
  NSArray<RNCPageCurlImageViewController *> *vcs = [self controllersForSlot:slot];
  if (!_spread || vcs.count == 1 || image == nil) {
    for (RNCPageCurlImageViewController *vc in vcs) {
      vc.imageView.image = image;
    }
    return;
  }
  CGImageRef cg = image.CGImage;
  size_t width = CGImageGetWidth(cg);
  size_t height = CGImageGetHeight(cg);
  CGImageRef left = CGImageCreateWithImageInRect(cg, CGRectMake(0, 0, width / 2, height));
  CGImageRef right = CGImageCreateWithImageInRect(cg, CGRectMake(width / 2, 0, width - width / 2, height));
  vcs[0].imageView.image = [UIImage imageWithCGImage:left scale:image.scale orientation:UIImageOrientationUp];
  vcs[1].imageView.image = [UIImage imageWithCGImage:right scale:image.scale orientation:UIImageOrientationUp];
  CGImageRelease(left);
  CGImageRelease(right);
}

- (void)clearSlot:(NSString *)slot
{
  NSLog(@"[page-curl] clear slot=%@ (absent)", slot);
  [self assignImage:nil toSlot:slot];
  for (RNCPageCurlImageViewController *vc in [self controllersForSlot:slot]) {
    vc.absent = YES;
  }
}

- (void)blankSlot:(NSString *)slot
{
  NSLog(@"[page-curl] blank slot=%@ (page exists, not baked)", slot);
  [self assignImage:nil toSlot:slot];
  for (RNCPageCurlImageViewController *vc in [self controllersForSlot:slot]) {
    vc.absent = NO;
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
  UIColor *paper = [UIColor colorWithRed:pixel[0] / 255.0 green:pixel[1] / 255.0 blue:pixel[2] / 255.0 alpha:1];
  [self paintPaper:paper];
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
    for (RNCPageCurlImageViewController *vc in [strongSelf controllersForSlot:slot]) {
      vc.absent = NO;
    }
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
  WKWebView *webView = _webView;
  if (webView == nil) {
    NSLog(@"[page-curl] bridge %@(%ld) failed: webview missing", fn, (long)page);
    completion(NO);
    return;
  }
  NSString *body = [NSString stringWithFormat:
      @"if (!window.nativePageCurl) { throw new Error('nativePageCurl bridge missing'); }"
       "return await window.nativePageCurl.%@(page);", fn];
  CFTimeInterval start = CACurrentMediaTime();
  [webView callAsyncJavaScript:body
                     arguments:@{@"page": @(page)}
                       inFrame:nil
                inContentWorld:WKContentWorld.pageWorld
             completionHandler:^(id result, NSError *error) {
    double ms = (CACurrentMediaTime() - start) * 1000.0;
    NSLog(@"[page-curl] bridge %@(%ld) took %.1fms error=%@", fn, (long)page, ms, error);
    completion(error == nil);
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

// the slot on the far side of the target page: bake it, curl onto blank paper for a page in
// the neighboring chunk, or nothing at the ends of the book
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
  [steps addObject:[self stepBlock:^{
    if (beyondChunk) {
      [weakSelf blankSlot:direction];
    } else {
      [weakSelf clearSlot:direction];
    }
  }]];
}

- (void)finishCycle:(BOOL)ok reason:(NSString *)reason
{
  _cycleRunning = NO;
  _coverHeld = NO;
  _pageController.view.hidden = YES;
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
  NSLog(@"[page-curl] full cycle start page=%ld/%ld chunk=%ld last=%d shown=%@", (long)_page, (long)_totalPages, (long)_chunkIndex, _isLastChunk, [self shownSlot]);

  __weak __typeof(self) weakSelf = self;
  NSMutableArray<RNCPageCurlStep> *steps = [NSMutableArray array];
  [steps addObject:[self stepSnapshot:RNCPageCurlSlotCurrent]];
  [steps addObject:[self stepBlock:^{
    __strong __typeof(weakSelf) strongSelf = weakSelf;
    [strongSelf showSlot:RNCPageCurlSlotCurrent];
    strongSelf->_pageController.view.hidden = NO;
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
  [self rotateSlotsToward:direction];
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
  if (_pageController == nil) {
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

#pragma mark - gestures

- (void)onPan:(UIPanGestureRecognizer *)pan
{
  CGPoint translation = [pan translationInView:_hostView];
  if (pan.state != UIGestureRecognizerStateChanged) {
    NSLog(@"[page-curl] pan state=%ld translation=%.1f,%.1f inFlight=%d hidden=%d", (long)pan.state, translation.x, translation.y, _transitionInFlight, _pageController.view.hidden);
  }
  if (pan.state == UIGestureRecognizerStateEnded && _transitionInFlight) {
    // UIKit's completion curve is fixed; scale its tempo with the release velocity so a gentle
    // release settles slowly and a flick lands fast
    CGPoint velocity = [pan velocityInView:_hostView];
    double speed = MIN(1.3, MAX(0.45, 0.45 + fabs(velocity.x) / 3000.0));
    CALayer *layer = _pageController.view.layer;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval local = [layer convertTime:now fromLayer:nil];
    layer.timeOffset = local;
    layer.beginTime = now;
    layer.speed = (float)speed;
    NSLog(@"[page-curl] release velocity=%.0f -> completion speed %.2f", velocity.x, speed);
  }
  if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled ||
      pan.state == UIGestureRecognizerStateFailed) {
    _edgeEmitted = NO;
    if (!_transitionInFlight) {
      NSLog(@"[page-curl] pan ended without a transition (ready=%d)", _ready);
      [self hideIfIdle];
      [self runPendingSettle];
    }
  }
}

- (void)resetCompletionSpeed
{
  CALayer *layer = _pageController.view.layer;
  if (layer.speed != 1.0f) {
    layer.speed = 1.0f;
    layer.timeOffset = 0;
    layer.beginTime = 0;
  }
}

- (nullable UIViewController *)neighborOf:(UIViewController *)viewController offset:(NSInteger)offset direction:(NSString *)direction
{
  NSInteger index = [_orderedControllers indexOfObject:(RNCPageCurlImageViewController *)viewController];
  RNCPageCurlImageViewController *from = (RNCPageCurlImageViewController *)viewController;
  if (index == NSNotFound) {
    return nil;
  }
  NSInteger target = index + offset;
  if (target < 0 || target >= (NSInteger)_orderedControllers.count) {
    return nil;
  }
  RNCPageCurlImageViewController *candidate = _orderedControllers[target];
  // a back face is only ever shown on the way to the front page beyond it
  RNCPageCurlImageViewController *landing = candidate;
  if (candidate.back) {
    NSInteger landingIndex = target + offset;
    if (landingIndex < 0 || landingIndex >= (NSInteger)_orderedControllers.count) {
      return nil;
    }
    landing = _orderedControllers[landingIndex];
  }
  BOOL hasImage = landing.imageView.image != nil;
  NSLog(@"[page-curl] dataSource %@(%@/%ld%@) -> %@/%ld%@ %@", direction, from.slot, (long)from.half, from.back ? @" back" : @"",
        candidate.slot, (long)candidate.half, candidate.back ? @" back" : @"",
        hasImage ? @"ok" : (landing.absent ? @"ABSENT" : @"BLANK"));
  if (!_ready) {
    NSLog(@"[page-curl] bakes not ready; no curl");
    return nil;
  }
  _pageController.view.hidden = NO;
  if (landing.absent) {
    return nil;
  }
  if (!hasImage && !_edgeEmitted && ![landing.slot isEqualToString:from.slot]) {
    _edgeEmitted = YES;
    [self emit:@"edge" direction:direction detail:nil];
  }
  return candidate;
}

- (nullable UIViewController *)pageViewController:(UIPageViewController *)pageViewController
                viewControllerBeforeViewController:(UIViewController *)viewController
{
  return [self neighborOf:viewController offset:-1 direction:@"previous"];
}

- (nullable UIViewController *)pageViewController:(UIPageViewController *)pageViewController
                 viewControllerAfterViewController:(UIViewController *)viewController
{
  return [self neighborOf:viewController offset:1 direction:@"next"];
}

- (UIPageViewControllerSpineLocation)pageViewController:(UIPageViewController *)pageViewController
                   spineLocationForInterfaceOrientation:(UIInterfaceOrientation)orientation
{
  NSLog(@"[page-curl] spineLocationForInterfaceOrientation %ld (spread=%d)", (long)orientation, _spread);
  [self showSlot:[self shownSlot]];
  return _spread ? UIPageViewControllerSpineLocationMid : UIPageViewControllerSpineLocationMin;
}

- (void)pageViewController:(UIPageViewController *)pageViewController
    willTransitionToViewControllers:(NSArray<UIViewController *> *)pendingViewControllers
{
  _transitionInFlight = YES;
  // locked for the whole turn; a cancelled turn hands the still-valid bakes back
  _ready = NO;
  RNCPageCurlImageViewController *pending = (RNCPageCurlImageViewController *)pendingViewControllers.firstObject;
  NSLog(@"[page-curl] willTransitionTo %@ (%lu controllers)", pending.slot, (unsigned long)pendingViewControllers.count);
  [self applyCurlLighting];
  __weak __typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf applyCurlLighting];
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [weakSelf applyCurlLighting];
  });
  if (!_dumpedCurlLayers) {
    _dumpedCurlLayers = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [weakSelf dumpCurlLayers];
    });
  }
}

// UIKit's curl is a private "pageCurl" Core Animation filter named "curl" on the curling layers;
// its declared inputs are inputFrontColor (a multiply tint on the page image, white by default),
// inputShadowColor (gray 0.15 by default), inputTime, inputAngle and inputRadius. A 0.15 gray
// shadow is lighter than a black page, so on dark paper the fold shows as a pale band; the shadow
// is re-derived from the paper instead.
- (void)applyCurlLighting
{
  UIColor *paper = _paperColor != nil ? RNCPageCurlColorFromCSS(_paperColor) : nil;
  if (paper == nil || _pageController == nil) {
    return;
  }
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [paper getRed:&r green:&g blue:&b alpha:&a];
  CGFloat keep = 0.15;
  UIColor *shadow = [UIColor colorWithRed:r * keep green:g * keep blue:b * keep alpha:1];
  NSUInteger count = [self applyCurlShadow:shadow toLayer:_pageController.view.layer];
  if (count > 0) {
    NSLog(@"[page-curl] curl shadow %@ applied to %lu layers", shadow, (unsigned long)count);
  }
}

- (NSUInteger)applyCurlShadow:(UIColor *)shadow toLayer:(CALayer *)layer
{
  NSUInteger count = 0;
  for (id filter in layer.filters) {
    NSString *type = nil;
    @try {
      type = [filter valueForKey:@"type"];
    } @catch (NSException *exception) {
      type = nil;
    }
    if (![type isEqualToString:@"pageCurl"]) {
      continue;
    }
    NSString *name = [filter valueForKey:@"name"] ?: @"curl";
    [layer setValue:(id)shadow.CGColor forKeyPath:[NSString stringWithFormat:@"filters.%@.inputShadowColor", name]];
    count += 1;
  }
  for (CALayer *sublayer in layer.sublayers) {
    count += [self applyCurlShadow:shadow toLayer:sublayer];
  }
  return count;
}

// spike diagnostics, once per process: what UIKit builds for the curl. Findings on iOS 26.4:
// two layers carry a CAFilter type "pageCurl" named "curl" (one front-only, one back-only);
// its declared inputs are inputAngle, inputBackEnabled, inputEndAngle, inputFrontColor (a
// multiply tint on the page image), inputFrontEnabled, inputRadius, inputShadowBounds,
// inputShadowColor, inputStartAngle and inputTime. The pale highlight along the fold is added
// by the shader itself and survives a pure black back face; nothing declared controls it.
- (void)dumpCurlLayers
{
  NSLog(@"[page-curl] layer dump begin");
  [self dumpLayer:_pageController.view.layer depth:0];
  NSLog(@"[page-curl] layer dump end");
}

- (void)dumpLayer:(CALayer *)layer depth:(NSInteger)depth
{
  NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
  NSMutableString *line = [NSMutableString stringWithFormat:@"%@%@ frame=%@ hidden=%d opacity=%.2f", indent, NSStringFromClass(layer.class), NSStringFromCGRect(layer.frame), layer.hidden, layer.opacity];
  if (layer.delegate != nil) {
    [line appendFormat:@" delegate=%@", NSStringFromClass([layer.delegate class])];
  }
  NSArray *filters = layer.filters;
  if (filters.count > 0) {
    [line appendFormat:@" filters=%@", filters];
  }
  if (layer.compositingFilter != nil) {
    [line appendFormat:@" compositingFilter=%@", layer.compositingFilter];
  }
  if (layer.backgroundFilters.count > 0) {
    [line appendFormat:@" backgroundFilters=%@", layer.backgroundFilters];
  }
  NSLog(@"[page-curl] %@", line);
  for (id filter in filters) {
    @try {
      NSString *type = [filter valueForKey:@"type"];
      NSString *description = [[filter description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
      NSLog(@"[page-curl] %@  filter class=%@ type=%@ name=%@ description=%@", indent, NSStringFromClass([filter class]), type, [filter valueForKey:@"name"], description);
      // the filter's selectors reveal its input names
      unsigned int methodCount = 0;
      Method *methods = class_copyMethodList([filter class], &methodCount);
      NSMutableArray<NSString *> *selectors = [NSMutableArray array];
      for (unsigned int i = 0; i < methodCount; i++) {
        [selectors addObject:NSStringFromSelector(method_getName(methods[i]))];
      }
      free(methods);
      NSLog(@"[page-curl] %@  filter selectors: %@", indent, [selectors componentsJoinedByString:@" "]);
      unsigned int propertyCount = 0;
      objc_property_t *properties = class_copyPropertyList([filter class], &propertyCount);
      NSMutableArray<NSString *> *names = [NSMutableArray array];
      for (unsigned int i = 0; i < propertyCount; i++) {
        [names addObject:[NSString stringWithUTF8String:property_getName(properties[i])]];
      }
      free(properties);
      NSLog(@"[page-curl] %@  filter properties: %@", indent, [names componentsJoinedByString:@" "]);
      unsigned int classMethodCount = 0;
      Method *classMethods = class_copyMethodList(object_getClass([filter class]), &classMethodCount);
      NSMutableArray<NSString *> *classSelectors = [NSMutableArray array];
      for (unsigned int i = 0; i < classMethodCount; i++) {
        [classSelectors addObject:NSStringFromSelector(method_getName(classMethods[i]))];
      }
      free(classMethods);
      NSLog(@"[page-curl] %@  filter class selectors: %@", indent, [classSelectors componentsJoinedByString:@" "]);
      // CAMLTypeForKey: answers with a type only for keys the filter type actually declares
      SEL camlType = NSSelectorFromString(@"CAMLTypeForKey:");
      // every input key string QuartzCore ships (strings of the simulator runtime binary)
      NSArray<NSString *> *candidates = @[@"inputAberrationAmount", @"inputAberrationAngle", @"inputAberrationHeight", @"inputAberrationOffset", @"inputAdaptive", @"inputAddColor", @"inputAddWhite", @"inputAllowsGroup", @"inputAlphaValues", @"inputAmount", @"inputAngle", @"inputAspectRatio", @"inputBackdropAware", @"inputBackEnabled", @"inputBias", @"inputBleedAmount", @"inputBleedBlurRadius", @"inputBleedColorMatrixBlack", @"inputBleedColorMatrixFillColor", @"inputBleedColorMatrixSaturation", @"inputBleedColorMatrixWhite", @"inputBleedDarkenBlend", @"inputBleedHeight", @"inputBleedOffset", @"inputBleedOpacity", @"inputBleedSaturation", @"inputBlueOffset", @"inputBlueValues", @"inputBlurRadius", @"inputBounds", @"inputClamp", @"inputClampPreserveHue", @"inputColor", @"inputColorMap", @"inputColorMatrix", @"inputCount", @"inputDisplayInvertAware", @"inputDither", @"inputEdgeEnd", @"inputEdgeOpacityEnd", @"inputEdgeOpacityStart", @"inputEdgeStart", @"inputEnd", @"inputEndAngle", @"inputExtendEdges", @"inputFaceColorMatrixBlack", @"inputFaceColorMatrixFillColor", @"inputFaceColorMatrixSaturation", @"inputFaceColorMatrixWhite", @"inputFaceOpacity", @"inputFade", @"inputFrontColor", @"inputFrontEnabled", @"inputGreenOffset", @"inputGreenValues", @"inputHardEdges", @"inputHSVSpace", @"inputInnerRefractionAmount", @"inputInnerRefractionHeight", @"inputIntermediateBitDepth", @"inputLinear", @"inputMaskImage", @"inputMaxHeadroom", @"inputNormalizeEdges", @"inputNormalizeEdgesTransparent", @"inputOffset", @"inputOuterRefractionAmount", @"inputOuterRefractionHeight", @"inputOverlayOpacity", @"inputPremultipliedValues", @"inputQuality", @"inputRadius", @"inputRedOffset", @"inputRedValues", @"inputRefractionAmount", @"inputRefractionAngle", @"inputRefractionHeight", @"inputRefractionOffset", @"inputRefractionOpacity", @"inputReversed", @"inputScale", @"inputSDRHoldingToneEnabled", @"inputSDRHoldingToneWhite", @"inputSDRShadowOpacity", @"inputShadowAmount", @"inputShadowBlurRadius", @"inputShadowBounds", @"inputShadowColor", @"inputShadowColorMatrixBlack", @"inputShadowColorMatrixFillColor", @"inputShadowColorMatrixSaturation", @"inputShadowColorMatrixWhite", @"inputShadowDistanceOffset", @"inputShadowHeight", @"inputShadowOffset", @"inputShadowOpacity", @"inputShadowRadius", @"inputShadowVibrancyContribution", @"inputSourceSublayerName", @"inputStart", @"inputStartAngle", @"inputTime", @"inputValues", @"inputValuesTransparent"];
      NSMutableArray<NSString *> *declared = [NSMutableArray array];
      for (NSString *key in candidates) {
        id typeName = nil;
        if ([filter respondsToSelector:camlType]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
          typeName = [filter performSelector:camlType withObject:key];
#pragma clang diagnostic pop
        }
        id value = nil;
        @try {
          value = [filter valueForKey:key];
        } @catch (NSException *exception) {
          value = nil;
        }
        if (typeName != nil || value != nil) {
          NSString *text = [[value description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
          [declared addObject:[NSString stringWithFormat:@"%@ (%@) = %@", key, typeName ?: @"?", text ?: @"nil"]];
        }
      }
      NSLog(@"[page-curl] %@  filter declared inputs: %@", indent, [declared componentsJoinedByString:@" | "]);
    } @catch (NSException *exception) {
      NSLog(@"[page-curl] %@  filter %@ (no introspection: %@)", indent, filter, exception.reason);
    }
  }
  for (CALayer *sublayer in layer.sublayers) {
    [self dumpLayer:sublayer depth:depth + 1];
  }
}

- (void)pageViewController:(UIPageViewController *)pageViewController
        didFinishAnimating:(BOOL)finished
   previousViewControllers:(NSArray<UIViewController *> *)previousViewControllers
       transitionCompleted:(BOOL)completed
{
  _transitionInFlight = NO;
  [self resetCompletionSpeed];
  NSString *shown = [self shownSlot];
  NSLog(@"[page-curl] didFinishAnimating finished=%d completed=%d shown=%@", finished, completed, shown);
  if (!completed || [shown isEqualToString:RNCPageCurlSlotCurrent]) {
    [self hideIfIdle];
    [self emit:@"cancel" direction:nil detail:nil];
    if (_pendingSettle != nil) {
      [self runPendingSettle];
    } else if (!_awaitingSettle && !_coverHeld) {
      [self unlock:@"curl cancelled"];
    }
    return;
  }
  [self emit:@"turn" direction:shown detail:[NSString stringWithFormat:@"from page %ld", (long)_page]];
  [self finishTurnToward:shown];
}

@end
