#import <Foundation/Foundation.h>

extern NSString *accessGroupId;
extern NSString *bundleId;

extern void rebindSecFuncs();

extern void initializeAppGroupMapping(void);
extern NSArray<NSString *> *signedApplicationGroups(void);
extern NSURL *preferredRealAppGroupURL(void);
extern NSString *preferredRealAppGroupIdentifier(void);
extern NSURL *sideloadFallbackAppGroupURL(void);
extern NSURL *getAppGroupPathIfExists(void);
extern BOOL isMetaAppGroupIdentifier(NSString *groupIdentifier);
extern NSDictionary *mappedApplicationGroupEntitlements(NSDictionary *entitlements);
extern NSDictionary *mappedGroupContainerURLs(NSDictionary *groupContainerURLs);

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
