#import "RNCWebViewModule.h"

#import "RNCWebViewDecisionManager.h"
#import "RNCWebViewImpl.h"

#ifdef RCT_NEW_ARCH_ENABLED
#import <React/RCTFabricComponentsPlugins.h>
#endif /* RCT_NEW_ARCH_ENABLED */

@implementation RNCWebViewModule

RCT_EXPORT_MODULE(RNCWebViewModule)

- (dispatch_queue_t)methodQueue
{
  return dispatch_get_main_queue();
}

RCT_EXPORT_METHOD(callAsyncJavaScript:(double)viewTag
                  functionBody:(NSString *)functionBody
                  argument:(NSString *)argument
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  RNCWebViewImpl *impl = [RNCWebViewImpl implForReactTag:(NSInteger)viewTag];
  if (impl == nil) {
    reject(@"E_NO_WEBVIEW", [NSString stringWithFormat:@"no webview with tag %d", (int)viewTag], nil);
    return;
  }
  [impl callAsyncJavaScript:functionBody argument:argument completion:^(id result, NSError *error) {
    if (error != nil) {
      reject(@"E_JS", error.localizedDescription, error);
      return;
    }
    resolve([result isKindOfClass:[NSString class]] ? result : [NSNull null]);
  }];
}

RCT_EXPORT_METHOD(isFileUploadSupported:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    if (resolve) {
        resolve(@(YES));
    }
}

RCT_EXPORT_METHOD(shouldStartLoadWithLockIdentifier:(BOOL)shouldStart lockIdentifier:(double)lockIdentifier)
{
    [[RNCWebViewDecisionManager getInstance] setResult:shouldStart forLockIdentifier:(int)lockIdentifier];
}

#ifdef RCT_NEW_ARCH_ENABLED
- (void)setEventEmitterCallback:(EventEmitterCallbackWrapper *)eventEmitterCallbackWrapper
{
  [super setEventEmitterCallback:eventEmitterCallbackWrapper];
  __weak RNCWebViewModule *weakSelf = self;
  [RNCWebViewImpl setFastMessageSink:^(NSInteger reactTag, NSString *data) {
    [weakSelf emitOnFastMessage:@{@"viewTag": @(reactTag), @"data": data}];
  }];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeRNCWebViewModuleSpecJSI>(params);
}
#endif /* RCT_NEW_ARCH_ENABLED */

Class RNCWebViewModuleCls(void) {
  return RNCWebViewModule.class;
}

@end
