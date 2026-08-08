#import "Header.h"

@interface METAAppGroup : NSObject
- (NSURL *)containerURL;
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

	// Do not hijack arbitrary third-party groups. Only original Meta-family group
	// identifiers are aliases for the real group carried by the resigned build.
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

	// METAAppGroup has already resolved a symbolic group name (for example
	// "app") by this point. If the original Meta entitlement is unavailable,
	// provide the one real cross-process App Group selected from this signature.
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

%hook NSBundle
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)extension inDirectory:(NSString *)subpath {
	NSString *path = %orig(name, extension, subpath);
	if (path || self != [NSBundle mainBundle] || ![subpath isEqualToString:@"mobileconfig_res"]) {
		return path;
	}

	// This Forum build packages the pmap resources under params_maps/, while
	// FBMobileConfigAdvancedSettingsViewController asks for mobileconfig_res/.
	// Keep the fix constrained to this one missing bundle-resource directory.
	return %orig(name, extension, @"params_maps");
}

- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)extension subdirectory:(NSString *)subpath {
	NSURL *URL = %orig(name, extension, subpath);
	if (URL || self != [NSBundle mainBundle] || ![subpath isEqualToString:@"mobileconfig_res"]) {
		return URL;
	}
	return %orig(name, extension, @"params_maps");
}
%end

%ctor {
	// Resolve the genuine signed group BEFORE installing LSBundleProxy and
	// NSFileManager hooks. This prevents recursive alias resolution and ensures
	// every Meta alias points at an actual iOS-managed shared container.
	initializeAppGroupMapping();
	%init;
}
