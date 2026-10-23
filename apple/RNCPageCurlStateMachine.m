#import "RNCPageCurlStateMachine.h"

NSString *RNCPageCurlStateName(RNCPageCurlState state)
{
  return @"?";
}

@implementation RNCPageCurlEffect
@end

@implementation RNCPageCurlStateMachine

- (BOOL)canBeginTurn
{
  return NO;
}

- (NSString *)summary
{
  return @"";
}

- (NSArray<RNCPageCurlEffect *> *)enable
{
  return @[];
}

- (void)teardown
{
}

- (NSArray<RNCPageCurlEffect *> *)settled:(NSDictionary *)settle
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)unsettled
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)touchEnded
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)tapped
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)turnBegan
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)turnFinishedToward:(NSString *)direction completed:(BOOL)completed
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)bakeFinished:(BOOL)ok
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)landingFinished:(BOOL)ok
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)settleRequestFinished:(BOOL)ok token:(NSUInteger)token
{
  return @[];
}

- (NSArray<RNCPageCurlEffect *> *)rebakeRequested:(NSString *)reason
{
  return @[];
}

@end
