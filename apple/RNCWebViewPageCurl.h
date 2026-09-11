#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "RNCPageCurlLog.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^RNCPageCurlEventBlock)(NSDictionary *event);

/**
 * Apple Books-style page curl over a WKWebView. Pages are bitmaps baked with
 * takeSnapshot; a Metal renderer draws them above the webview and is hidden at
 * rest. The content frame reports settles through the "pageCurl" script message
 * handler; the controller drives the webview through window.nativePageCurl.
 * Events (logging only): touch, tap, turn, cancel, edge, settled, ready.
 */
@interface RNCWebViewPageCurl : NSObject

- (instancetype)initWithHostView:(UIView *)hostView webView:(WKWebView *)webView;

@property (nonatomic, copy, nullable) RNCPageCurlEventBlock onEvent;
// "edge" = one sheet with the spine at the left edge (default), "middle" = facing pages with
// the spine in the center
@property (nonatomic, copy, nullable) NSString *spine;
// when the paper is unset the top-left pixel of the current bake is used, and the back of a
// sheet defaults to the paper faded toward the opposite extreme
@property (nonatomic, strong, nullable) UIColor *paperColor;
@property (nonatomic, strong, nullable) UIColor *backColor;
@property (nonatomic, strong, nullable) UIColor *shadowColor;
@property (nonatomic, strong, nullable) NSNumber *shadowOpacity;
@property (nonatomic, strong, nullable) UIColor *highlightColor;
@property (nonatomic, strong, nullable) NSNumber *highlightOpacity;
// JSON object of tuning knobs (radius, bend-in, shadow widths, completion timing); unknown keys
// are ignored and missing keys keep their defaults, so knobs can be added without codegen
@property (nonatomic, copy, nullable) NSString *tuning;

- (void)setEnabled:(BOOL)enabled;
- (void)handleMessage:(NSDictionary *)message;
- (void)layoutWithBounds:(CGRect)bounds;
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
