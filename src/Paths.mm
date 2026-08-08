#import <stdlib.h>

#import "Header.h"

static NSString *homeDirectoryPath(void) {
	const char *homeCString = getenv("HOME");
	NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
	if (home.length == 0) {
		home = NSHomeDirectory();
	}
	return home;
}

BOOL createDirectoryIfNotExists(NSString *path) {
	if (path.length == 0) {
		return NO;
	}

	NSFileManager *fileManager = [NSFileManager defaultManager];
	BOOL isDirectory = NO;
	if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
		return isDirectory;
	}

	NSError *error = nil;
	BOOL created = [fileManager createDirectoryAtPath:path
						withIntermediateDirectories:YES
									 attributes:nil
										  error:&error];
	return created && error == nil;
}

NSArray<NSString *> *signedApplicationGroups(void) {
	LSBundleProxy *proxy = [LSBundleProxy bundleProxyForCurrentProcess];
	id value = proxy.entitlements[@"com.apple.security.application-groups"];
	if (![value isKindOfClass:[NSArray class]]) {
		return @[];
	}

	NSMutableArray<NSString *> *groups = [NSMutableArray array];
	for (id entry in (NSArray *)value) {
		if ([entry isKindOfClass:[NSString class]] && [entry length] > 0) {
			[groups addObject:entry];
		}
	}

	// Prefer the dedicated Ryuk2 group used by the resigned Forum build, then
	// the legacy Ryuk group. Keep every other signed group as a generic fallback
	// so zxPluginsInject remains usable outside Forum.
	NSArray<NSString *> *preferred = @[
		@"group.ryuk2.anoxclan.com",
		@"group.com.anoxclan.ryuk",
	];

	NSMutableArray<NSString *> *ordered = [NSMutableArray arrayWithCapacity:groups.count];
	for (NSString *candidate in preferred) {
		if ([groups containsObject:candidate]) {
			[ordered addObject:candidate];
		}
	}
	for (NSString *candidate in groups) {
		if (![ordered containsObject:candidate]) {
			[ordered addObject:candidate];
		}
	}
	return ordered;
}

static NSURL *URLFromGroupContainerValue(id value) {
	if ([value isKindOfClass:[NSURL class]]) {
		return value;
	}
	if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
		return [NSURL fileURLWithPath:value isDirectory:YES];
	}
	return nil;
}

NSURL *preferredRealAppGroupURL(void) {
	LSBundleProxy *proxy = [LSBundleProxy bundleProxyForCurrentProcess];
	NSDictionary *containerURLs = proxy.groupContainerURLs;
	if (![containerURLs isKindOfClass:[NSDictionary class]]) {
		return nil;
	}

	for (NSString *groupIdentifier in signedApplicationGroups()) {
		NSURL *URL = URLFromGroupContainerValue(containerURLs[groupIdentifier]);
		if (URL) {
			return URL;
		}
	}
	return nil;
}

NSURL *sideloadFallbackAppGroupURL(void) {
	NSString *documentsPath = [homeDirectoryPath() stringByAppendingPathComponent:@"Documents"];
	NSString *appGroupPath = [documentsPath stringByAppendingPathComponent:@"AppGroup"];
	if (!createDirectoryIfNotExists(appGroupPath)) {
		return nil;
	}
	return [NSURL fileURLWithPath:appGroupPath isDirectory:YES];
}

NSURL *getAppGroupPathIfExists(void) {
	NSURL *realURL = preferredRealAppGroupURL();
	return realURL ?: sideloadFallbackAppGroupURL();
}
