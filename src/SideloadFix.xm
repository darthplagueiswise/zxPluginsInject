#import "Header.h"

@interface METAAppGroup : NSObject
- (NSURL *)containerURL;
@end

@interface FBMobileConfigAdvancedSettingsViewController : NSObject
- (NSString *)getParamsMapPath:(NSString *)resourceName;
@end

%hook CKContainer
- (id)_setupWithContainerID:(id)a options:(id)b { return nil; }
- (id)_initWithContainerIdentifier:(id)a { return nil; }
%end

%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)entitlements {
	NSMutableDictionary *mutEntitlements = [entitlements mutableCopy];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-container-environment"];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-services"];
	return %orig([mutEntitlements copy]);
}
%end

%hook LSBundleProxy
- (NSDictionary *)entitlements {
	NSDictionary *entitlements = %orig;
	return mappedApplicationGroupEntitlements(entitlements);
}

- (NSDictionary *)groupContainerURLs {
	NSDictionary *containerURLs = %orig;
	return mappedGroupContainerURLs(containerURLs);
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	NSURL *URL = %orig(groupIdentifier);
	if (URL) {
		return URL;
	}

	if (!isMetaAppGroupIdentifier(groupIdentifier)) {
		return nil;
	}

	URL = preferredRealAppGroupURL();
	return URL ?: sideloadFallbackAppGroupURL();
}
%end

%hook METAAppGroup
- (NSURL *)containerURL {
	NSURL *URL = %orig;
	if (URL) {
		return URL;
	}
	return getAppGroupPathIfExists();
}
%end

%hook NSUserDefaults
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (!isMetaAppGroupIdentifier(suiteName)) {
		return %orig(suiteName, container);
	}

	NSURL *mappedContainer = preferredRealAppGroupURL();
	return %orig(suiteName, mappedContainer ?: container);
}
%end

%hook FBMobileConfigAdvancedSettingsViewController
- (NSString *)getParamsMapPath:(NSString *)resourceName {
	NSString *path = %orig(resourceName);
	if (path.length > 0 || resourceName.length == 0) {
		return path;
	}

	// Forum's Advanced Settings asks for mobileconfig_res/<name>.txt, while the
	// shipped IPA stores the same resources in params_maps/. Hook the exact
	// consumer instead of globally changing NSBundle resource semantics.
	NSString *fileName = resourceName.pathExtension.length > 0
		? resourceName
		: [resourceName stringByAppendingPathExtension:@"txt"];
	NSString *candidate = [[[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:@"params_maps"]
		stringByAppendingPathComponent:fileName];
	return [[NSFileManager defaultManager] fileExistsAtPath:candidate] ? candidate : path;
}
%end

%ctor {
	// Resolve the genuine signed group before installing the aliases. SecTask is
	// used by Paths.mm first, so this does not depend on LSBundleProxy startup.
	initializeAppGroupMapping();
	%init;
}
