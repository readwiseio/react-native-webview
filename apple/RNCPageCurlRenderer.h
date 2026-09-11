#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#import "RNCPageCurlLog.h"

NS_ASSUME_NONNULL_BEGIN

// a page bitmap placed in the view; texture nil draws paper; texRect selects part of the texture
@interface RNCPageCurlPage : NSObject
@property (nonatomic, strong, nullable) id<MTLTexture> texture;
@property (nonatomic, assign) CGRect rect;
@property (nonatomic, assign) CGRect texRect;
+ (instancetype)pageWithTexture:(nullable id<MTLTexture>)texture rect:(CGRect)rect texRect:(CGRect)texRect;
@end

// shading knobs, all read from the host's tuning JSON (see RNCWebViewPageCurl); widths are
// multiples of the bend radius, strengths multiples of the shadow/highlight opacity
typedef struct {
  float castWidthFloor;       // edge shadow width when the bend is flat, x free radius
  float castWidthPerRadius;   // extra width per unit of current radius
  float castStrengthFloor;    // edge shadow strength when the bend is flat
  float castSoftness;         // 0 = full strength right at the edge; higher fades in before it
  float aheadNear;            // under-page shadow ahead of the bend starts fading here, x radius
  float aheadFar;             // and is gone here, x radius
  float aheadStrength;        // multiplier on the shadow ahead of the bend
  float bendDarken;           // darkening at the steepest part of the bend
  float crestPosition;        // highlight band centre along the bend, in half-turns (0..1)
  float crestWidth;           // highlight band width, in half-turns
  float riseScale;            // second band on the rising side, relative to the crest
  float tightFade;            // how much the shading at the fold thins as the radius shrinks to a crease (0..1)
  float backShowThrough;      // how much of the front shows through the back of a single sheet (0 = opaque)
} RNCPageCurlShading;

/**
 * Draws the page curl: flat pages underneath, then one sheet bent around a cylinder whose
 * axis is set by the curl start point S and the dragged point F (both in sheet-local
 * coordinates where the sheet curls from its right edge; `mirrored` flips that to the left).
 * Every input comes from the host and is set before the first draw; nothing is read back.
 */
@interface RNCPageCurlRenderer : MTKView

@property (nonatomic, assign) RNCPageCurlShading shading;

@property (nonatomic, strong) UIColor *paperColor;
@property (nonatomic, strong) UIColor *backColor;
@property (nonatomic, strong) UIColor *shadowColor;
@property (nonatomic, assign) CGFloat shadowOpacity;
@property (nonatomic, strong) UIColor *highlightColor;
@property (nonatomic, assign) CGFloat highlightOpacity;

@property (nonatomic, copy, nullable) NSArray<RNCPageCurlPage *> *underPages;
@property (nonatomic, strong, nullable) RNCPageCurlPage *sheet;
@property (nonatomic, strong, nullable) id<MTLTexture> sheetBackTexture;
@property (nonatomic, assign) CGRect sheetBackTexRect;
@property (nonatomic, assign) BOOL mirrored;
// NO draws the sheet flat, for use as a static cover
@property (nonatomic, assign) BOOL curling;
@property (nonatomic, assign) CGPoint curlStart;
@property (nonatomic, assign) CGPoint curlFinger;
@property (nonatomic, assign) CGFloat curlRadius;
// the bend radius of a free curl; the edge shadow's floor width is derived from it
@property (nonatomic, assign) CGFloat curlRadiusMax;
// 0..1 multiplier on the crease shading, ramped in by the host over the first part of the drag
@property (nonatomic, assign) CGFloat curlBendStrength;

- (instancetype)initWithFrame:(CGRect)frame;
- (nullable id<MTLTexture>)textureFromImage:(UIImage *)image;

@end

NS_ASSUME_NONNULL_END
