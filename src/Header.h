#import <Foundation/Foundation.h>

extern NSString *accessGroupId;
extern NSString *bundleId;

extern void rebindSecFuncs();
extern void rebindPathFuncs();

extern BOOL createDirectoryIfNotExists(NSString *path);
extern NSURL *getAppGroupPathIfExists();
extern NSString *canonicalizedSideloadPath(NSString *path);
extern NSURL *canonicalizedSideloadURL(NSURL *url);
extern void migrateLegacyMobileConfigIfNeeded();

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
