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

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	// Preserve a container that iOS can already resolve. This is important for
	// apps that were resigned with their original App Group still available.
	NSURL *URL = %orig(groupIdentifier);
	if (URL || groupIdentifier.length == 0 || ![groupIdentifier hasPrefix:@"group."]) {
		return URL;
	}

	// Forum asks METAAppGroup for original Meta group identifiers that are not
	// present in the resigned profile. Resolve those requests through a REAL
	// application group present in the current process' signed entitlements.
	for (NSString *signedGroup in signedApplicationGroups()) {
		if ([signedGroup isEqualToString:groupIdentifier]) {
			continue;
		}
		URL = %orig(signedGroup);
		if (URL) {
			return URL;
		}
	}

	// LSBundleProxy can still expose the real group URL even when the public
	// NSFileManager lookup did not. Keep Documents/AppGroup only as the final
	// generic sideload fallback, never as the preferred Forum container.
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
	if (![suiteName hasPrefix:@"group."]) {
		return %orig(suiteName, container);
	}

	NSURL *mappedContainer = [[NSFileManager defaultManager]
		containerURLForSecurityApplicationGroupIdentifier:suiteName];
	return %orig(suiteName, mappedContainer ?: container);
}
%end

%hook NSBundle
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)extension inDirectory:(NSString *)subpath {
	NSString *path = %orig(name, extension, subpath);
	if (path || self != [NSBundle mainBundle] || ![subpath isEqualToString:@"mobileconfig_res"]) {
		return path;
	}

	// FBMobileConfigAdvancedSettingsViewController looks for its pmap assets in
	// mobileconfig_res/, while this Forum IPA packages the exact resources in
	// params_maps/. Redirect only that missing resource directory lookup.
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
	%init;
}
