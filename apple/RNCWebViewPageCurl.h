#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^RNCPageCurlEventBlock)(NSDictionary *event);

/**
 * Apple Books-style page curl over a WKWebView. Pages are bitmaps baked with
 * takeSnapshot; a UIPageViewController (pageCurl style) hosts them above the
 * webview and is hidden at rest. The content frame reports settles through the
 * "pageCurl" script message handler; the controller drives the webview through
 * window.nativePageCurl. Events (logging only): touch, tap, turn, cancel, edge,
 * settled, ready.
 */
@interface RNCWebViewPageCurl : NSObject

- (instancetype)initWithHostView:(UIView *)hostView webView:(WKWebView *)webView;

@property (nonatomic, copy, nullable) RNCPageCurlEventBlock onEvent;
// "edge" = one sheet with the spine at the left edge (default), "middle" = facing pages with
// the spine in the center
@property (nonatomic, copy, nullable) NSString *spine;
// CSS color for the paper behind the bakes and the back of a curling sheet; when unset the
// top-left pixel of the current bake is used
@property (nonatomic, copy, nullable) NSString *paperColor;

- (void)setEnabled:(BOOL)enabled;
- (void)handleMessage:(NSDictionary *)message;
- (void)layoutWithBounds:(CGRect)bounds;
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
