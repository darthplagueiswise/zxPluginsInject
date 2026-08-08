#import <Foundation/Foundation.h>

extern NSString *accessGroupId;
extern NSString *bundleId;

extern void rebindSecFuncs();
extern void rebindPathFuncs();

extern BOOL createDirectoryIfNotExists(NSString *path);
extern NSArray<NSString *> *signedApplicationGroups(void);
extern NSURL *preferredRealAppGroupURL(void);
extern NSURL *sideloadFallbackAppGroupURL(void);
extern NSURL *getAppGroupPathIfExists(void);

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
