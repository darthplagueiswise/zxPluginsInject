#import <stdlib.h>

#import "Header.h"

static NSArray<NSString *> *gSignedApplicationGroups = nil;
static NSString *gPreferredRealAppGroupIdentifier = nil;
static NSURL *gPreferredRealAppGroupURL = nil;
static NSDictionary *gOriginalEntitlements = nil;
static NSDictionary *gOriginalGroupContainerURLs = nil;
static dispatch_once_t gAppGroupMappingOnce;

static NSArray<NSString *> *knownMetaAppGroupIdentifiers(void) {
	static NSArray<NSString *> *identifiers = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		identifiers = @[
			@"group.com.burbn.family",
			@"group.com.burbn.instagram",
			@"group.com.facebook.Bishop",
			@"group.com.facebook.Messenger",
			@"group.com.facebook.Talk",
			@"group.com.facebook.family",
			@"group.com.facebook.family.appattestation",
			@"group.com.facebook.family.appattestation.reinstallationflagalreadyset",
			@"group.com.facebook.family.appgrouptokenshare",
			@"group.com.facebook.internal.lantern",
			@"group.com.facebook.msysstorage",
			@"group.com.facebook.twilight",
			@"group.com.facebook.workchat.workspeed",
			@"group.com.facebookwork.family",
			@"group.com.metaplatforms.family",
			@"group.net.whatsapp.WhatsApp.shared",
			@"group.net.whatsapp.WhatsAppSMB.shared",
			@"group.net.whatsapp.family",
		];
	});
	return identifiers;
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

static NSArray<NSString *> *normalizedSignedGroups(NSDictionary *entitlements) {
	id value = entitlements[@"com.apple.security.application-groups"];
	if (![value isKindOfClass:[NSArray class]]) {
		return @[];
	}

	NSMutableArray<NSString *> *groups = [NSMutableArray array];
	for (id entry in (NSArray *)value) {
		if ([entry isKindOfClass:[NSString class]] && [entry length] > 0 && ![groups containsObject:entry]) {
			[groups addObject:entry];
		}
	}
	return [groups copy];
}

static NSArray<NSString *> *orderedCandidateGroups(NSArray<NSString *> *signedGroups, NSDictionary *entitlements) {
	NSMutableArray<NSString *> *ordered = [NSMutableArray array];

	// Prefer the group matching the bundle identifier embedded in the resigning
	// application-identifier entitlement. Example:
	// S4Q99652S6.ryuk2.anoxclan.com -> group.ryuk2.anoxclan.com.
	NSString *applicationIdentifier = entitlements[@"application-identifier"];
	if ([applicationIdentifier isKindOfClass:[NSString class]]) {
		NSRange separator = [applicationIdentifier rangeOfString:@"."];
		if (separator.location != NSNotFound && NSMaxRange(separator) < applicationIdentifier.length) {
			NSString *signedBundleIdentifier = [applicationIdentifier substringFromIndex:NSMaxRange(separator)];
			NSString *derivedGroup = [@"group." stringByAppendingString:signedBundleIdentifier];
			if ([signedGroups containsObject:derivedGroup]) {
				[ordered addObject:derivedGroup];
			}
		}
	}

	// Known Forum/Ryuk signing groups remain stable fallbacks, but are only used
	// when they are actually present in this process' signed entitlements.
	for (NSString *candidate in @[@"group.ryuk2.anoxclan.com", @"group.com.anoxclan.ryuk"]) {
		if ([signedGroups containsObject:candidate] && ![ordered containsObject:candidate]) {
			[ordered addObject:candidate];
		}
	}

	for (NSString *candidate in signedGroups) {
		if (![ordered containsObject:candidate]) {
			[ordered addObject:candidate];
		}
	}
	return ordered;
}

void initializeAppGroupMapping(void) {
	dispatch_once(&gAppGroupMappingOnce, ^{
		LSBundleProxy *proxy = [LSBundleProxy bundleProxyForCurrentProcess];
		NSDictionary *entitlements = proxy.entitlements;
		NSDictionary *containerURLs = proxy.groupContainerURLs;

		gOriginalEntitlements = [entitlements isKindOfClass:[NSDictionary class]] ? [entitlements copy] : @{};
		gOriginalGroupContainerURLs = [containerURLs isKindOfClass:[NSDictionary class]] ? [containerURLs copy] : @{};
		gSignedApplicationGroups = normalizedSignedGroups(gOriginalEntitlements);

		NSFileManager *fileManager = [NSFileManager defaultManager];
		for (NSString *groupIdentifier in orderedCandidateGroups(gSignedApplicationGroups, gOriginalEntitlements)) {
			NSURL *URL = URLFromGroupContainerValue(gOriginalGroupContainerURLs[groupIdentifier]);
			if (!URL) {
				// This executes before the Logos hooks are installed, so it is the real
				// Foundation App Group lookup for the signed identifier.
				URL = [fileManager containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
			}
			if (URL) {
				gPreferredRealAppGroupIdentifier = [groupIdentifier copy];
				gPreferredRealAppGroupURL = [URL copy];
				break;
			}
		}
	});
}

NSArray<NSString *> *signedApplicationGroups(void) {
	initializeAppGroupMapping();
	return gSignedApplicationGroups ?: @[];
}

NSURL *preferredRealAppGroupURL(void) {
	initializeAppGroupMapping();
	return gPreferredRealAppGroupURL;
}

NSString *preferredRealAppGroupIdentifier(void) {
	initializeAppGroupMapping();
	return gPreferredRealAppGroupIdentifier;
}

BOOL isMetaAppGroupIdentifier(NSString *groupIdentifier) {
	if (![groupIdentifier isKindOfClass:[NSString class]] || groupIdentifier.length == 0) {
		return NO;
	}

	if ([knownMetaAppGroupIdentifiers() containsObject:groupIdentifier]) {
		return YES;
	}

	return [groupIdentifier hasPrefix:@"group.com.facebook."] ||
		[groupIdentifier hasPrefix:@"group.com.facebookwork."] ||
		[groupIdentifier hasPrefix:@"group.com.metaplatforms."] ||
		[groupIdentifier hasPrefix:@"group.com.burbn."] ||
		[groupIdentifier hasPrefix:@"group.net.whatsapp."];
}

NSDictionary *mappedApplicationGroupEntitlements(NSDictionary *entitlements) {
	initializeAppGroupMapping();
	if (!gPreferredRealAppGroupURL || ![entitlements isKindOfClass:[NSDictionary class]]) {
		return entitlements;
	}

	NSMutableDictionary *mapped = [entitlements mutableCopy];
	NSMutableArray<NSString *> *groups = [NSMutableArray arrayWithArray:normalizedSignedGroups(entitlements)];
	for (NSString *alias in knownMetaAppGroupIdentifiers()) {
		if (![groups containsObject:alias]) {
			[groups addObject:alias];
		}
	}
	mapped[@"com.apple.security.application-groups"] = [groups copy];
	return [mapped copy];
}

NSDictionary *mappedGroupContainerURLs(NSDictionary *groupContainerURLs) {
	initializeAppGroupMapping();
	if (!gPreferredRealAppGroupURL) {
		return groupContainerURLs;
	}

	NSMutableDictionary *mapped = [groupContainerURLs isKindOfClass:[NSDictionary class]]
		? [groupContainerURLs mutableCopy]
		: [NSMutableDictionary dictionary];
	for (NSString *alias in knownMetaAppGroupIdentifiers()) {
		mapped[alias] = gPreferredRealAppGroupURL;
	}
	return [mapped copy];
}

static NSString *homeDirectoryPath(void) {
	const char *homeCString = getenv("HOME");
	NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
	return home.length > 0 ? home : NSHomeDirectory();
}

static BOOL createDirectoryIfNotExists(NSString *path) {
	if (path.length == 0) {
		return NO;
	}
	NSFileManager *fileManager = [NSFileManager defaultManager];
	BOOL isDirectory = NO;
	if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
		return isDirectory;
	}
	return [fileManager createDirectoryAtPath:path
		withIntermediateDirectories:YES
		attributes:nil
		error:nil];
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
