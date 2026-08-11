#import <Foundation/Foundation.h>

#ifdef __cplusplus
#include <chrono>
#endif

extern NSString *accessGroupId;
extern NSString *bundleId;

extern void rebindSecFuncs(void);
extern void rebindPathFuncs(void);

extern BOOL createDirectoryIfNotExists(NSString *path);
extern NSURL *getAppGroupPathIfExists(void);
extern NSString *canonicalizedSideloadPath(NSString *path);
extern NSURL *canonicalizedSideloadURL(NSURL *url);
extern void migrateLegacyMobileConfigIfNeeded(void);

@interface LSBundleProxy : NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
