#import "RNCPageCurlRenderer.h"
#import <simd/simd.h>

static const NSUInteger RNCPageCurlGridColumns = 128;
static const NSUInteger RNCPageCurlGridRows = 96;

// mirrored in the shader source below
typedef struct {
  simd_float2 viewSize;
  simd_float2 pageOrigin;
  simd_float2 pageSize;
  simd_float2 sheetOrigin;
  simd_float2 sheetSize;
  simd_float2 axisOrigin;
  simd_float2 axisNormal;
  float radius;
  float progress;
  float mirrored;
  float curling;
  simd_float4 paperColor;
  simd_float4 backColor;
  simd_float4 shadowColor;
  simd_float4 highlightColor;
  simd_float4 frontTexRect;
  simd_float4 backTexRect;
  float hasFront;
  float hasBack;
  float radiusMax;
  float pad;
  // shading knobs: A = cast width floor, cast width per radius, cast strength floor, cast softness;
  // B = ahead near, ahead far, bend darken, crest position; C = crest width, rise scale
  simd_float4 shadingA;
  simd_float4 shadingB;
  simd_float4 shadingC;
  // D = ahead strength, tight fade, 0, 0
  simd_float4 shadingD;
} RNCPageCurlUniforms;

static const char *const RNCPageCurlShaderSource = R"metal(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
  float2 viewSize;
  float2 pageOrigin;
  float2 pageSize;
  float2 sheetOrigin;
  float2 sheetSize;
  float2 axisOrigin;
  float2 axisNormal;
  float radius;
  float progress;
  float mirrored;
  float curling;
  float4 paperColor;
  float4 backColor;
  float4 shadowColor;
  float4 highlightColor;
  float4 frontTexRect;
  float4 backTexRect;
  float hasFront;
  float hasBack;
  float radiusMax;
  float pad;
  float4 shadingA;
  float4 shadingB;
  float4 shadingC;
  float4 shadingD;
};

// shading at the fold thins out as the bend tightens: 1 at the free radius, (1 - tightFade) at a sharp crease
static float tightness(float R, constant Uniforms &u) {
  float fade = u.shadingD.y;
  return (1.0 - fade) + fade * clamp(R / max(u.radiusMax, 1.0), 0.0, 1.0);
}

// the folded-over edge shadows what lies under it; it softens as the bend flattens but keeps a floor
// so it does not vanish before the sheet has landed
static float castShadow(float distanceOutside, float R, constant Uniforms &u) {
  float width = u.radiusMax * u.shadingA.x + R * u.shadingA.y;
  float floorStrength = u.shadingA.z;
  float strength = u.shadowColor.a * (floorStrength + (1.0 - floorStrength) * R / max(u.radiusMax, 1.0));
  return strength * (1.0 - smoothstep(-width * u.shadingA.w, width, distanceOutside));
}

struct VOut {
  float4 position [[position]];
  float2 uv;
  float2 local;
  float s;
};

static float4 clipFromView(float2 view, float2 viewSize, float depth) {
  return float4(view.x / viewSize.x * 2.0 - 1.0, 1.0 - view.y / viewSize.y * 2.0, depth, 1.0);
}

vertex VOut sheetVertex(uint vid [[vertex_id]],
                        const device float2 *verts [[buffer(0)]],
                        constant Uniforms &u [[buffer(1)]]) {
  float2 uv = verts[vid];
  float2 p = uv * u.sheetSize;
  float s = dot(p - u.axisOrigin, u.axisNormal);
  float2 pos = p;
  float z = 0.0;
  if (u.curling > 0.5 && s > 0.0) {
    float R = u.radius;
    if (R > 0.0 && s < M_PI_F * R) {
      float a = s / R;
      pos = p - u.axisNormal * s + u.axisNormal * R * sin(a);
      z = R * (1.0 - cos(a));
    } else {
      // folded over: mirrored across the fold, flat at the bend's height (a zero radius is a sharp fold)
      pos = p - u.axisNormal * (2.0 * s - M_PI_F * R);
      z = 2.0 * R;
    }
  }
  float2 rel = pos;
  if (u.mirrored > 0.5) {
    rel.x = u.sheetSize.x - rel.x;
  }
  VOut o;
  o.position = clipFromView(u.sheetOrigin + rel, u.viewSize, 0.5 - z / 4000.0);
  o.uv = uv;
  o.local = p;
  o.s = s;
  return o;
}

fragment float4 sheetFragment(VOut in [[stage_in]],
                              bool frontFacing [[front_facing]],
                              texture2d<float> front [[texture(0)]],
                              texture2d<float> back [[texture(1)]],
                              sampler smp [[sampler(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
  float3 color;
  if (frontFacing) {
    float fu = u.mirrored > 0.5 ? 1.0 - in.uv.x : in.uv.x;
    float2 tc = u.frontTexRect.xy + float2(fu, in.uv.y) * u.frontTexRect.zw;
    color = u.hasFront > 0.5 ? front.sample(smp, tc).rgb : u.paperColor.rgb;
  } else {
    float bu = u.mirrored > 0.5 ? in.uv.x : 1.0 - in.uv.x;
    float2 tc = u.backTexRect.xy + float2(bu, in.uv.y) * u.backTexRect.zw;
    color = u.hasBack > 0.5 ? back.sample(smp, tc).rgb : u.backColor.rgb;
  }
  if (u.curling < 0.5 || u.radius <= 0.0) {
    return float4(color, 1.0);
  }
  float R = u.radius;
  float a = clamp(in.s / R, 0.0, M_PI_F);
  float sa = sin(a);
  // the bend darkens as it turns away from an overhead light, and picks up a glossy band just past the crest
  // shadingC.z ramps the crease shading in over the first part of the drag
  float darken = u.shadowColor.a * u.shadingB.z * u.shadingC.z * tightness(R, u) * sa * sa;
  float crest = exp(-pow((a - u.shadingB.w * M_PI_F) / (u.shadingC.x * M_PI_F), 2.0));
  float rise = u.shadingC.y * exp(-pow((a - 0.3 * M_PI_F) / (0.12 * M_PI_F), 2.0));
  float highlight = u.highlightColor.a * tightness(R, u) * (crest + rise);
  float cast = 0.0;
  if (frontFacing && in.s < 0.5 * M_PI_F * R) {
    // the folded-over part is the sheet mirrored across the line s = pi R / 2; its edge shadows the flat front
    float2 q = in.local - u.axisNormal * (2.0 * in.s - M_PI_F * R);
    float2 outside = max(max(-q, q - u.sheetSize), 0.0);
    cast = castShadow(length(outside), R, u);
  }
  color = mix(color, u.shadowColor.rgb, clamp(darken + cast, 0.0, 1.0));
  color = mix(color, u.highlightColor.rgb, clamp(highlight, 0.0, 1.0));
  return float4(color, 1.0);
}

vertex VOut underVertex(uint vid [[vertex_id]],
                        const device float2 *verts [[buffer(0)]],
                        constant Uniforms &u [[buffer(1)]]) {
  float2 uv = verts[vid];
  float2 view = u.pageOrigin + uv * u.pageSize;
  float2 rel = view - u.sheetOrigin;
  if (u.mirrored > 0.5) {
    rel.x = u.sheetSize.x - rel.x;
  }
  VOut o;
  o.position = clipFromView(view, u.viewSize, 0.51);
  o.uv = uv;
  o.local = rel;
  o.s = 0.0;
  return o;
}

fragment float4 underFragment(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
  float2 tc = u.frontTexRect.xy + in.uv * u.frontTexRect.zw;
  float3 color = u.hasFront > 0.5 ? tex.sample(smp, tc).rgb : u.paperColor.rgb;
  if (u.curling > 0.5 && u.radius > 0.0) {
    float R = u.radius;
    float sp = dot(in.local - u.axisOrigin, u.axisNormal);
    float shadow;
    if (sp > 0.0) {
      // the page ahead of the bend sits in its shadow
      shadow = u.shadowColor.a * u.shadingD.x * tightness(R, u) * (1.0 - smoothstep(R * u.shadingB.x, R * u.shadingB.y, sp));
    } else {
      // the page the folded-over part lands on: its edge shadows it, like the sheet's own flat front
      float2 q = in.local - u.axisNormal * (2.0 * sp - M_PI_F * R);
      float2 outside = max(max(-q, q - u.sheetSize), 0.0);
      shadow = castShadow(length(outside), R, u);
    }
    color = mix(color, u.shadowColor.rgb, clamp(shadow, 0.0, 1.0));
  }
  return float4(color, 1.0);
}
)metal";

static simd_float4 RNCPageCurlFloat4(UIColor *color, CGFloat opacity)
{
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [color getRed:&r green:&g blue:&b alpha:&a];
  return simd_make_float4((float)r, (float)g, (float)b, (float)opacity);
}

static simd_float4 RNCPageCurlRectFloat4(CGRect rect)
{
  return simd_make_float4((float)rect.origin.x, (float)rect.origin.y, (float)rect.size.width, (float)rect.size.height);
}

@implementation RNCPageCurlPage

+ (instancetype)pageWithTexture:(id<MTLTexture>)texture rect:(CGRect)rect texRect:(CGRect)texRect
{
  RNCPageCurlPage *page = [RNCPageCurlPage new];
  page.texture = texture;
  page.rect = rect;
  page.texRect = texRect;
  return page;
}

@end

@implementation RNCPageCurlRenderer {
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _sheetPipeline;
  id<MTLRenderPipelineState> _underPipeline;
  id<MTLDepthStencilState> _depthState;
  id<MTLSamplerState> _sampler;
  id<MTLBuffer> _gridVertices;
  id<MTLBuffer> _gridIndices;
  NSUInteger _gridIndexCount;
  id<MTLBuffer> _quadVertices;
  MTKTextureLoader *_loader;
  BOOL _pipelineFailed;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if ((self = [super initWithFrame:frame device:device])) {
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    self.framebufferOnly = YES;
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;
    self.opaque = YES;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _paperColor = [UIColor whiteColor];
    _backColor = [UIColor colorWithWhite:0.88 alpha:1];
    _shadowColor = [UIColor blackColor];
    _shadowOpacity = 0.35;
    _highlightColor = [UIColor whiteColor];
    _highlightOpacity = 0.2;
    _underPages = @[];
    _sheetBackTexRect = CGRectMake(0, 0, 1, 1);
    RNCPageCurlShading shading = {0.5, 0.9, 0.6, 0.35, 0.8, 2.4, 0.55, 0.62, 0.13, 0.35, 1.0, 0.7};
    _shading = shading;
    _curlBendStrength = 1;
    _queue = [device newCommandQueue];
    _loader = [[MTKTextureLoader alloc] initWithDevice:device];
    [self buildPipelines];
    [self buildMeshes];
  }
  return self;
}

- (void)buildPipelines
{
  CFTimeInterval start = CACurrentMediaTime();
  NSError *error = nil;
  MTLCompileOptions *options = [MTLCompileOptions new];
  id<MTLLibrary> library = [self.device newLibraryWithSource:[NSString stringWithUTF8String:RNCPageCurlShaderSource] options:options error:&error];
  if (library == nil) {
    NSLog(@"[page-curl] metal: shader compile failed: %@", error);
    _pipelineFailed = YES;
    return;
  }
  MTLRenderPipelineDescriptor *sheet = [MTLRenderPipelineDescriptor new];
  sheet.vertexFunction = [library newFunctionWithName:@"sheetVertex"];
  sheet.fragmentFunction = [library newFunctionWithName:@"sheetFragment"];
  sheet.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  sheet.depthAttachmentPixelFormat = self.depthStencilPixelFormat;
  _sheetPipeline = [self.device newRenderPipelineStateWithDescriptor:sheet error:&error];
  if (_sheetPipeline == nil) {
    NSLog(@"[page-curl] metal: sheet pipeline failed: %@", error);
    _pipelineFailed = YES;
    return;
  }
  MTLRenderPipelineDescriptor *under = [MTLRenderPipelineDescriptor new];
  under.vertexFunction = [library newFunctionWithName:@"underVertex"];
  under.fragmentFunction = [library newFunctionWithName:@"underFragment"];
  under.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  under.depthAttachmentPixelFormat = self.depthStencilPixelFormat;
  _underPipeline = [self.device newRenderPipelineStateWithDescriptor:under error:&error];
  if (_underPipeline == nil) {
    NSLog(@"[page-curl] metal: under pipeline failed: %@", error);
    _pipelineFailed = YES;
    return;
  }
  MTLDepthStencilDescriptor *depth = [MTLDepthStencilDescriptor new];
  depth.depthCompareFunction = MTLCompareFunctionLess;
  depth.depthWriteEnabled = YES;
  _depthState = [self.device newDepthStencilStateWithDescriptor:depth];
  MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
  sampler.minFilter = MTLSamplerMinMagFilterLinear;
  sampler.magFilter = MTLSamplerMinMagFilterLinear;
  sampler.mipFilter = MTLSamplerMipFilterNotMipmapped;
  sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
  _sampler = [self.device newSamplerStateWithDescriptor:sampler];
  NSLog(@"[page-curl] metal: pipelines ready in %.1fms on %@", (CACurrentMediaTime() - start) * 1000.0, self.device.name);
}

- (void)buildMeshes
{
  NSUInteger columns = RNCPageCurlGridColumns;
  NSUInteger rows = RNCPageCurlGridRows;
  NSUInteger vertexCount = (columns + 1) * (rows + 1);
  simd_float2 *vertices = (simd_float2 *)malloc(sizeof(simd_float2) * vertexCount);
  for (NSUInteger row = 0; row <= rows; row++) {
    for (NSUInteger column = 0; column <= columns; column++) {
      vertices[row * (columns + 1) + column] = simd_make_float2((float)column / columns, (float)row / rows);
    }
  }
  _gridVertices = [self.device newBufferWithBytes:vertices length:sizeof(simd_float2) * vertexCount options:MTLResourceStorageModeShared];
  free(vertices);

  _gridIndexCount = columns * rows * 6;
  uint16_t *indices = (uint16_t *)malloc(sizeof(uint16_t) * _gridIndexCount);
  NSUInteger i = 0;
  for (NSUInteger row = 0; row < rows; row++) {
    for (NSUInteger column = 0; column < columns; column++) {
      uint16_t topLeft = (uint16_t)(row * (columns + 1) + column);
      uint16_t topRight = topLeft + 1;
      uint16_t bottomLeft = (uint16_t)((row + 1) * (columns + 1) + column);
      uint16_t bottomRight = bottomLeft + 1;
      // clockwise on screen, the default front-facing winding
      indices[i++] = topLeft;
      indices[i++] = topRight;
      indices[i++] = bottomLeft;
      indices[i++] = topRight;
      indices[i++] = bottomRight;
      indices[i++] = bottomLeft;
    }
  }
  _gridIndices = [self.device newBufferWithBytes:indices length:sizeof(uint16_t) * _gridIndexCount options:MTLResourceStorageModeShared];
  free(indices);

  simd_float2 quad[6] = {
    simd_make_float2(0, 0), simd_make_float2(1, 0), simd_make_float2(0, 1),
    simd_make_float2(1, 0), simd_make_float2(1, 1), simd_make_float2(0, 1),
  };
  _quadVertices = [self.device newBufferWithBytes:quad length:sizeof(quad) options:MTLResourceStorageModeShared];
}

- (id<MTLTexture>)textureFromImage:(UIImage *)image
{
  CGImageRef cg = image.CGImage;
  if (cg == nil) {
    return nil;
  }
  CFTimeInterval start = CACurrentMediaTime();
  // MTKTextureLoader refuses the snapshot's bitmap layout; redraw it as plain BGRA instead
  size_t width = CGImageGetWidth(cg);
  size_t height = CGImageGetHeight(cg);
  size_t bytesPerRow = width * 4;
  void *bytes = calloc(height, bytesPerRow);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(bytes, width, height, 8, bytesPerRow, colorSpace,
                                               kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(colorSpace);
  if (context == nil) {
    free(bytes);
    NSLog(@"[page-curl] metal: bitmap context failed for %zux%zu", width, height);
    return nil;
  }
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
  CGContextRelease(context);
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModeShared;
  id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:bytes bytesPerRow:bytesPerRow];
  free(bytes);
  NSLog(@"[page-curl] metal: texture %zux%zu in %.1fms", width, height, (CACurrentMediaTime() - start) * 1000.0);
  return texture;
}

- (void)renderNow
{
  [self draw];
}

#pragma mark - geometry

- (RNCPageCurlUniforms)baseUniforms
{
  RNCPageCurlUniforms u;
  memset(&u, 0, sizeof(u));
  CGSize size = self.bounds.size;
  u.viewSize = simd_make_float2((float)size.width, (float)size.height);
  CGRect sheetRect = _sheet != nil ? _sheet.rect : self.bounds;
  u.sheetOrigin = simd_make_float2((float)sheetRect.origin.x, (float)sheetRect.origin.y);
  u.sheetSize = simd_make_float2((float)sheetRect.size.width, (float)sheetRect.size.height);
  u.mirrored = _mirrored ? 1 : 0;
  u.curling = (_curling && _sheet != nil) ? 1 : 0;
  u.progress = (float)_curlProgress;
  u.radiusMax = (float)MAX(_curlRadiusMax, 1);
  u.shadingA = simd_make_float4(_shading.castWidthFloor, _shading.castWidthPerRadius, _shading.castStrengthFloor, _shading.castSoftness);
  u.shadingB = simd_make_float4(_shading.aheadNear, _shading.aheadFar, _shading.bendDarken, _shading.crestPosition);
  u.shadingC = simd_make_float4(_shading.crestWidth, _shading.riseScale, (float)_curlBendStrength, 0);
  u.shadingD = simd_make_float4(_shading.aheadStrength, _shading.tightFade, 0, 0);
  u.paperColor = RNCPageCurlFloat4(_paperColor, 1);
  u.backColor = RNCPageCurlFloat4(_backColor, 1);
  u.shadowColor = RNCPageCurlFloat4(_shadowColor, _shadowOpacity);
  u.highlightColor = RNCPageCurlFloat4(_highlightColor, _highlightOpacity);
  if (u.curling > 0) {
    CGFloat dx = _curlStart.x - _curlFinger.x;
    CGFloat dy = _curlStart.y - _curlFinger.y;
    CGFloat distance = sqrt(dx * dx + dy * dy);
    simd_float2 normal = simd_make_float2(1, 0);
    if (distance > 0.5) {
      normal = simd_make_float2((float)(dx / distance), (float)(dy / distance));
    }
    CGFloat R = _curlRadius;
    // the fold sits half way between S and its folded-over image F, plus the half turn around the cylinder
    CGFloat foldDistance = (distance + M_PI * R) / 2.0;
    u.axisOrigin = simd_make_float2((float)(_curlStart.x - normal.x * foldDistance), (float)(_curlStart.y - normal.y * foldDistance));
    u.axisNormal = normal;
    u.radius = (float)R;
  }
  return u;
}

typedef struct {
  CGFloat x, y, z, s;
} RNCPageCurlBent;

static double RNCPageCurlSmoothstep(double e0, double e1, double x)
{
  double t = MIN(MAX((x - e0) / (e1 - e0), 0.0), 1.0);
  return t * t * (3 - 2 * t);
}

// the same bend as the vertex shader, for one sheet-local point: view-space x/y, height and fold side
- (RNCPageCurlBent)bendLocal:(CGPoint)p uniforms:(const RNCPageCurlUniforms *)u
{
  CGFloat nx = u->axisNormal.x, ny = u->axisNormal.y;
  CGFloat s = (p.x - u->axisOrigin.x) * nx + (p.y - u->axisOrigin.y) * ny;
  CGFloat px = p.x, py = p.y, z = 0;
  CGFloat R = u->radius;
  if (u->curling > 0.5 && s > 0) {
    if (R > 0 && s < M_PI * R) {
      px = p.x - nx * s + nx * R * sin(s / R);
      py = p.y - ny * s + ny * R * sin(s / R);
      z = R * (1 - cos(s / R));
    } else {
      px = p.x - nx * (2 * s - M_PI * R);
      py = p.y - ny * (2 * s - M_PI * R);
      z = 2 * R;
    }
  }
  CGFloat rel = u->mirrored > 0.5 ? u->sheetSize.x - px : px;
  RNCPageCurlBent bent = {u->sheetOrigin.x + rel, u->sheetOrigin.y + py, z, s};
  return bent;
}

// per-frame debugging: geometry, where key sheet points land (the spine corners must stay put),
// and the shade the shaders apply at fixed distances from the fold
- (NSString *)curlDescription
{
  RNCPageCurlUniforms u = [self baseUniforms];
  NSMutableString *line = [NSMutableString stringWithFormat:@"S=%.0f,%.0f F=%.0f,%.0f R=%.1f p=%.2f axis=%.0f,%.0f n=%.2f,%.2f sheet=%@ mirrored=%d curling=%d |",
                           _curlStart.x, _curlStart.y, _curlFinger.x, _curlFinger.y, u.radius, u.progress, u.axisOrigin.x, u.axisOrigin.y,
                           u.axisNormal.x, u.axisNormal.y, NSStringFromCGRect(_sheet.rect), _mirrored, _curling];
  CGFloat w = u.sheetSize.x;
  CGFloat h = u.sheetSize.y;
  CGFloat y = _curlFinger.y;
  for (CGFloat fraction = 0; fraction <= 1.0001; fraction += 0.25) {
    RNCPageCurlBent bent = [self bendLocal:CGPointMake(w * fraction, y) uniforms:&u];
    [line appendFormat:@" x%.0f->%.0f(z%.0f)", w * fraction, bent.x, bent.z];
  }
  RNCPageCurlBent top = [self bendLocal:CGPointMake(0, 0) uniforms:&u];
  RNCPageCurlBent bottom = [self bendLocal:CGPointMake(0, h) uniforms:&u];
  [line appendFormat:@" | spineTop->%.0f,%.0f(z%.0f s%.0f) spineBottom->%.0f,%.0f(z%.0f s%.0f)", top.x, top.y, top.z, top.s, bottom.x, bottom.y, bottom.z, bottom.s];
  if (u.curling > 0.5 && u.radius > 0) {
    double R = u.radius;
    double a = u.shadowColor.w;
    RNCPageCurlShading t = _shading;
    double castWidth = u.radiusMax * t.castWidthFloor + R * t.castWidthPerRadius;
    double castStrength = a * (t.castStrengthFloor + (1 - t.castStrengthFloor) * R / u.radiusMax);
    double castStart = -castWidth * t.castSoftness;
    double tight = (1 - t.tightFade) + t.tightFade * MIN(MAX(R / u.radiusMax, 0), 1);
    double ahead = a * t.aheadStrength * tight;
    [line appendFormat:@" | shade tight=%.2f under@R=%.2f @1.5R=%.2f @2R=%.2f @3R=%.2f castWidth=%.0f cast@0=%.2f @0.5w=%.2f @w=%.2f bendMax=%.2f crest=%.2f",
     tight,
     ahead * (1 - RNCPageCurlSmoothstep(t.aheadNear * R, t.aheadFar * R, R)),
     ahead * (1 - RNCPageCurlSmoothstep(t.aheadNear * R, t.aheadFar * R, 1.5 * R)),
     ahead * (1 - RNCPageCurlSmoothstep(t.aheadNear * R, t.aheadFar * R, 2 * R)),
     ahead * (1 - RNCPageCurlSmoothstep(t.aheadNear * R, t.aheadFar * R, 3 * R)),
     castWidth,
     castStrength * (1 - RNCPageCurlSmoothstep(castStart, castWidth, 0)),
     castStrength * (1 - RNCPageCurlSmoothstep(castStart, castWidth, 0.5 * castWidth)),
     castStrength * (1 - RNCPageCurlSmoothstep(castStart, castWidth, castWidth)),
     a * t.bendDarken * _curlBendStrength * tight,
     (double)u.highlightColor.w * tight];
    NSUInteger index = 0;
    for (RNCPageCurlPage *page in _underPages) {
      [line appendFormat:@" under%lu=%@%@", (unsigned long)index, NSStringFromCGRect(page.rect), page.texture ? @"" : @"(paper)"];
      index += 1;
    }
  }
  return line;
}

- (void)drawRect:(CGRect)rect
{
  if (_pipelineFailed || _sheetPipeline == nil) {
    return;
  }
  NSLog(@"[page-curl] draw %@", [self curlDescription]);
  id<CAMetalDrawable> drawable = self.currentDrawable;
  MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
  if (drawable == nil || pass == nil) {
    NSLog(@"[page-curl] metal: no drawable (hidden=%d)", self.hidden);
    return;
  }
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [_paperColor getRed:&r green:&g blue:&b alpha:&a];
  pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1);
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.depthAttachment.loadAction = MTLLoadActionClear;
  pass.depthAttachment.clearDepth = 1.0;

  id<MTLCommandBuffer> commands = [_queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
  [encoder setDepthStencilState:_depthState];
  [encoder setCullMode:MTLCullModeNone];
  [encoder setFragmentSamplerState:_sampler atIndex:0];

  RNCPageCurlUniforms base = [self baseUniforms];

  [encoder setRenderPipelineState:_underPipeline];
  [encoder setVertexBuffer:_quadVertices offset:0 atIndex:0];
  for (RNCPageCurlPage *page in _underPages) {
    RNCPageCurlUniforms u = base;
    u.pageOrigin = simd_make_float2((float)page.rect.origin.x, (float)page.rect.origin.y);
    u.pageSize = simd_make_float2((float)page.rect.size.width, (float)page.rect.size.height);
    u.frontTexRect = RNCPageCurlRectFloat4(page.texRect);
    u.hasFront = page.texture != nil ? 1 : 0;
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentTexture:page.texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }

  if (_sheet != nil) {
    RNCPageCurlUniforms u = base;
    u.pageOrigin = u.sheetOrigin;
    u.pageSize = u.sheetSize;
    u.frontTexRect = RNCPageCurlRectFloat4(_sheet.texRect);
    u.backTexRect = RNCPageCurlRectFloat4(_sheetBackTexRect);
    u.hasFront = _sheet.texture != nil ? 1 : 0;
    u.hasBack = _sheetBackTexture != nil ? 1 : 0;
    [encoder setRenderPipelineState:_sheetPipeline];
    // mirroring flips the winding, so the front face would read as the back
    [encoder setFrontFacingWinding:_mirrored ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [encoder setVertexBuffer:_gridVertices offset:0 atIndex:0];
    [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
    [encoder setFragmentTexture:_sheet.texture atIndex:0];
    [encoder setFragmentTexture:_sheetBackTexture atIndex:1];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:_gridIndexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:_gridIndices
                 indexBufferOffset:0];
  }

  [encoder endEncoding];
  [commands presentDrawable:drawable];
  [commands commit];
}

@end
