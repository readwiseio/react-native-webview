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
  float bendStrength;
  float castWidthFloor;
  float castWidthPerRadius;
  float castStrengthFloor;
  float castSoftness;
  float aheadNear;
  float aheadFar;
  float aheadStrength;
  float bendDarken;
  float crestPosition;
  float crestWidth;
  float riseScale;
  float tightFade;
  float backShowThrough;
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
  float bendStrength;
  float castWidthFloor;
  float castWidthPerRadius;
  float castStrengthFloor;
  float castSoftness;
  float aheadNear;
  float aheadFar;
  float aheadStrength;
  float bendDarken;
  float crestPosition;
  float crestWidth;
  float riseScale;
  float tightFade;
  float backShowThrough;
};

// shading at the fold thins out as the bend tightens: 1 at the free radius, (1 - tightFade) at a sharp crease
static float tightness(float R, constant Uniforms &u) {
  return (1.0 - u.tightFade) + u.tightFade * clamp(R / max(u.radiusMax, 1.0), 0.0, 1.0);
}

// the folded-over edge shadows what lies under it; it softens as the bend flattens but keeps a floor
// so it does not vanish before the sheet has landed
static float castShadow(float distanceOutside, float R, constant Uniforms &u) {
  float width = u.radiusMax * u.castWidthFloor + R * u.castWidthPerRadius;
  float strength = u.shadowColor.a * (u.castStrengthFloor + (1.0 - u.castStrengthFloor) * R / max(u.radiusMax, 1.0));
  return strength * (1.0 - smoothstep(-width * u.castSoftness, width, distanceOutside));
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
    if (u.hasBack > 0.5) {
      color = back.sample(smp, tc).rgb;
    } else {
      color = u.backColor.rgb;
      if (u.hasFront > 0.5) {
        // the paper is slightly translucent: the front shows through faintly, mirrored, as its
        // deviation from the paper colour
        float fu = u.mirrored > 0.5 ? 1.0 - in.uv.x : in.uv.x;
        float3 ink = front.sample(smp, u.frontTexRect.xy + float2(fu, in.uv.y) * u.frontTexRect.zw).rgb;
        color = clamp(color - u.backShowThrough * (u.paperColor.rgb - ink), 0.0, 1.0);
      }
    }
  }
  if (u.curling < 0.5 || u.radius <= 0.0) {
    return float4(color, 1.0);
  }
  float R = u.radius;
  float a = clamp(in.s / R, 0.0, M_PI_F);
  float sa = sin(a);
  // the bend darkens as it turns away from an overhead light, and picks up a glossy band just past the crest
  float darken = u.shadowColor.a * u.bendDarken * u.bendStrength * tightness(R, u) * sa * sa;
  float crest = exp(-pow((a - u.crestPosition * M_PI_F) / (u.crestWidth * M_PI_F), 2.0));
  float rise = u.riseScale * exp(-pow((a - 0.3 * M_PI_F) / (0.12 * M_PI_F), 2.0));
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
      shadow = u.shadowColor.a * u.aheadStrength * tightness(R, u) * (1.0 - smoothstep(R * u.aheadNear, R * u.aheadFar, sp));
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

static const MTLPixelFormat RNCPageCurlColorFormat = MTLPixelFormatBGRA8Unorm;
static const MTLPixelFormat RNCPageCurlDepthFormat = MTLPixelFormatDepth32Float;

// compiled once per process: a renderer is made on every enable, spine change and webview rebuild
typedef struct {
  id<MTLRenderPipelineState> sheet;
  id<MTLRenderPipelineState> under;
  id<MTLDepthStencilState> depth;
  id<MTLSamplerState> sampler;
} RNCPageCurlPipelines;

static RNCPageCurlPipelines RNCPageCurlSharedPipelines(id<MTLDevice> device)
{
  static RNCPageCurlPipelines pipelines;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    CFTimeInterval start = CACurrentMediaTime();
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:RNCPageCurlShaderSource] options:[MTLCompileOptions new] error:&error];
    if (library == nil) {
      RNCPageCurlLog(@"[page-curl] metal: shader compile failed: %@", error);
      return;
    }
    MTLRenderPipelineDescriptor *sheet = [MTLRenderPipelineDescriptor new];
    sheet.vertexFunction = [library newFunctionWithName:@"sheetVertex"];
    sheet.fragmentFunction = [library newFunctionWithName:@"sheetFragment"];
    sheet.colorAttachments[0].pixelFormat = RNCPageCurlColorFormat;
    sheet.depthAttachmentPixelFormat = RNCPageCurlDepthFormat;
    pipelines.sheet = [device newRenderPipelineStateWithDescriptor:sheet error:&error];
    if (pipelines.sheet == nil) {
      RNCPageCurlLog(@"[page-curl] metal: sheet pipeline failed: %@", error);
      return;
    }
    MTLRenderPipelineDescriptor *under = [MTLRenderPipelineDescriptor new];
    under.vertexFunction = [library newFunctionWithName:@"underVertex"];
    under.fragmentFunction = [library newFunctionWithName:@"underFragment"];
    under.colorAttachments[0].pixelFormat = RNCPageCurlColorFormat;
    under.depthAttachmentPixelFormat = RNCPageCurlDepthFormat;
    pipelines.under = [device newRenderPipelineStateWithDescriptor:under error:&error];
    if (pipelines.under == nil) {
      RNCPageCurlLog(@"[page-curl] metal: under pipeline failed: %@", error);
      return;
    }
    MTLDepthStencilDescriptor *depth = [MTLDepthStencilDescriptor new];
    depth.depthCompareFunction = MTLCompareFunctionLess;
    depth.depthWriteEnabled = YES;
    pipelines.depth = [device newDepthStencilStateWithDescriptor:depth];
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.mipFilter = MTLSamplerMipFilterNotMipmapped;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    pipelines.sampler = [device newSamplerStateWithDescriptor:sampler];
    RNCPageCurlLog(@"[page-curl] metal: pipelines ready in %.1fms on %@", (CACurrentMediaTime() - start) * 1000.0, device.name);
  });
  return pipelines;
}

@implementation RNCPageCurlRenderer {
  id<MTLCommandQueue> _queue;
  RNCPageCurlPipelines _pipelines;
  id<MTLBuffer> _gridVertices;
  id<MTLBuffer> _gridIndices;
  NSUInteger _gridIndexCount;
  id<MTLBuffer> _quadVertices;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if ((self = [super initWithFrame:frame device:device])) {
    self.colorPixelFormat = RNCPageCurlColorFormat;
    self.depthStencilPixelFormat = RNCPageCurlDepthFormat;
    self.framebufferOnly = YES;
    self.paused = YES;
    self.enableSetNeedsDisplay = YES;
    self.opaque = YES;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _queue = [device newCommandQueue];
    _pipelines = RNCPageCurlSharedPipelines(device);
    [self buildMeshes];
  }
  return self;
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
    RNCPageCurlLog(@"[page-curl] metal: bitmap context failed for %zux%zu", width, height);
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
  RNCPageCurlLog(@"[page-curl] metal: texture %zux%zu in %.1fms", width, height, (CACurrentMediaTime() - start) * 1000.0);
  return texture;
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
  u.radiusMax = (float)MAX(_curlRadiusMax, 1);
  u.bendStrength = (float)_curlBendStrength;
  u.castWidthFloor = _shading.castWidthFloor;
  u.castWidthPerRadius = _shading.castWidthPerRadius;
  u.castStrengthFloor = _shading.castStrengthFloor;
  u.castSoftness = _shading.castSoftness;
  u.aheadNear = _shading.aheadNear;
  u.aheadFar = _shading.aheadFar;
  u.aheadStrength = _shading.aheadStrength;
  u.bendDarken = _shading.bendDarken;
  u.crestPosition = _shading.crestPosition;
  u.crestWidth = _shading.crestWidth;
  u.riseScale = _shading.riseScale;
  u.tightFade = _shading.tightFade;
  u.backShowThrough = _shading.backShowThrough;
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

- (void)drawRect:(CGRect)rect
{
  if (_pipelines.sheet == nil || _pipelines.under == nil) {
    return;
  }
  RNCPageCurlUniforms base = [self baseUniforms];
  RNCPageCurlLog(@"[page-curl] draw S=%.0f,%.0f F=%.0f,%.0f R=%.1f axis=%.0f,%.0f n=%.2f,%.2f sheet=%@ mirrored=%d curling=%d under=%lu",
                      _curlStart.x, _curlStart.y, _curlFinger.x, _curlFinger.y, base.radius, base.axisOrigin.x, base.axisOrigin.y, base.axisNormal.x,
                      base.axisNormal.y, NSStringFromCGRect(_sheet.rect), _mirrored, _curling, (unsigned long)_underPages.count);
  id<CAMetalDrawable> drawable = self.currentDrawable;
  MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
  if (drawable == nil || pass == nil) {
    RNCPageCurlLog(@"[page-curl] metal: no drawable (hidden=%d)", self.hidden);
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
  [encoder setDepthStencilState:_pipelines.depth];
  [encoder setCullMode:MTLCullModeNone];
  [encoder setFragmentSamplerState:_pipelines.sampler atIndex:0];

  [encoder setRenderPipelineState:_pipelines.under];
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
    [encoder setRenderPipelineState:_pipelines.sheet];
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
