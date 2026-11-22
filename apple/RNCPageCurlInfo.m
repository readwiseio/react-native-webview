#import "RNCPageCurlInfo.h"

// bump when the calls between RNCWebViewPageCurl and the content frame change
static const NSInteger RNCPageCurlProtocol = 2;

@implementation RNCPageCurlInfo

RCT_EXPORT_MODULE(RNCPageCurlInfo)

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (NSDictionary *)constantsToExport
{
#if TARGET_OS_IOS
  return @{@"protocol": @(RNCPageCurlProtocol)};
#else
  return @{};
#endif
}

@end
