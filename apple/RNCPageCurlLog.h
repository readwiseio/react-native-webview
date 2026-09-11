#import <Foundation/Foundation.h>

// every page curl log line goes through here; the pageCurlDebugLogging prop switches it on
extern BOOL RNCPageCurlLoggingEnabled;

#define RNCPageCurlLog(...)            \
  do {                                 \
    if (RNCPageCurlLoggingEnabled) {   \
      NSLog(__VA_ARGS__);              \
    }                                  \
  } while (0)
