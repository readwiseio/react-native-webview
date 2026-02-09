#import "RNCAssetSchemeHandler.h"

@implementation RNCAssetSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    NSURL *url = urlSchemeTask.request.URL;
    NSString *path = url.path;

    // Strip leading slash from path to get the filename
    if ([path hasPrefix:@"/"]) {
        path = [path substringFromIndex:1];
    }

    // URL-decode the path (handles brackets and other special chars)
    NSString *fileName = [path stringByRemovingPercentEncoding];
    if (!fileName || fileName.length == 0) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }

    // Find the file in the app bundle
    NSString *bundleResourcePath = [[NSBundle mainBundle] resourcePath];
    NSString *fullPath = [bundleResourcePath stringByAppendingPathComponent:fileName];

    if (![[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:fullPath];
    if (!data) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }

    // Determine MIME type from extension
    NSString *mimeType = @"application/octet-stream";
    NSString *ext = [fileName pathExtension];
    if ([ext isEqualToString:@"woff2"]) {
        mimeType = @"font/woff2";
    } else if ([ext isEqualToString:@"ttf"]) {
        mimeType = @"font/ttf";
    } else if ([ext isEqualToString:@"otf"]) {
        mimeType = @"font/otf";
    } else if ([ext isEqualToString:@"woff"]) {
        mimeType = @"font/woff";
    }

    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url
                                                        MIMEType:mimeType
                                           expectedContentLength:data.length
                                                textEncodingName:nil];

    [urlSchemeTask didReceiveResponse:response];
    [urlSchemeTask didReceiveData:data];
    [urlSchemeTask didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    // Requests complete synchronously, nothing to cancel
}

@end
