#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

#import "Header.h"

static NSArray<NSString *> *gSignedApplicationGroups = nil;
static NSString *gPreferredRealAppGroupIdentifier = nil;
static NSURL *gPreferredRealAppGroupURL = nil;
static NSDictionary *gOriginalEntitlements = nil;
static NSDictionary *gOriginalGroupContainerURLs = nil;
static dispatch_once_t gAppGroupMappingOnce;

typedef CFTypeRef (*ZXSecTaskCreateFromSelfFn)(CFAllocatorRef allocator);
typedef CFTypeRef (*ZXSecTaskCopyValueForEntitlementFn)(CFTypeRef task, CFStringRef entitlement, CFErrorRef *error);

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

static id runtimeSendObject(id target, SEL selector) {
	if (!target || !selector || ![target respondsToSelector:selector]) {
		return nil;
	}
	return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static NSDictionary *taskEntitlements(void) {
	ZXSecTaskCreateFromSelfFn createTask = (ZXSecTaskCreateFromSelfFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
	ZXSecTaskCopyValueForEntitlementFn copyEntitlement = (ZXSecTaskCopyValueForEntitlementFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
	if (!createTask || !copyEntitlement) {
		return nil;
	}

	CFTypeRef task = createTask(kCFAllocatorDefault);
	if (!task) {
		return nil;
	}

	NSMutableDictionary *entitlements = [NSMutableDictionary dictionary];
	for (NSString *key in @[@"com.apple.security.application-groups", @"application-identifier"]) {
		CFTypeRef value = copyEntitlement(task, (__bridge CFStringRef)key, NULL);
		if (value) {
			entitlements[key] = CFBridgingRelease(value);
		}
	}
	CFRelease(task);
	return entitlements.count ? [entitlements copy] : nil;
}

static NSDictionary *bundleProxyEntitlements(NSDictionary **containerURLsOut) {
	Class proxyClass = NSClassFromString(@"LSBundleProxy");
	id proxy = runtimeSendObject((id)proxyClass, sel_registerName("bundleProxyForCurrentProcess"));
	NSDictionary *entitlements = runtimeSendObject(proxy, sel_registerName("entitlements"));
	NSDictionary *containerURLs = runtimeSendObject(proxy, sel_registerName("groupContainerURLs"));
	if (containerURLsOut) {
		*containerURLsOut = [containerURLs isKindOfClass:[NSDictionary class]] ? containerURLs : nil;
	}
	return [entitlements isKindOfClass:[NSDictionary class]] ? entitlements : nil;
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

	// Prefer a group derived from the *current* signed application identifier.
	// There are deliberately no product/bundle-specific group names here.
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

	for (NSString *candidate in signedGroups) {
		if (![ordered containsObject:candidate]) {
			[ordered addObject:candidate];
		}
	}
	return ordered;
}

void initializeAppGroupMapping(void) {
	dispatch_once(&gAppGroupMappingOnce, ^{
		NSDictionary *proxyContainerURLs = nil;
		NSDictionary *proxyEntitlements = bundleProxyEntitlements(&proxyContainerURLs);
		NSDictionary *signedEntitlements = taskEntitlements();
		NSDictionary *entitlements = signedEntitlements ?: proxyEntitlements ?: @{};

		gOriginalEntitlements = [entitlements copy];
		gOriginalGroupContainerURLs = [proxyContainerURLs copy] ?: @{};
		gSignedApplicationGroups = normalizedSignedGroups(gOriginalEntitlements);

		NSFileManager *fileManager = [NSFileManager defaultManager];
		for (NSString *groupIdentifier in orderedCandidateGroups(gSignedApplicationGroups, gOriginalEntitlements)) {
			NSURL *URL = URLFromGroupContainerValue(gOriginalGroupContainerURLs[groupIdentifier]);
			if (!URL) {
				// Runs before the Logos hooks are installed, so this is the genuine
				// entitlement lookup for a group actually present in the signature.
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
	return [fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
}

NSURL *sideloadFallbackAppGroupURL(void) {
	NSString *documentsPath = [homeDirectoryPath() stringByAppendingPathComponent:@"Documents"];
	NSString *appGroupPath = [documentsPath stringByAppendingPathComponent:@"AppGroup"];
	if (!createDirectoryIfNotExists(appGroupPath)) {
		return nil;
	}
	return [NSURL fileURLWithPath:appGroupPath isDirectory:YES];
}

static NSURL *aliasTargetURL(void) {
	// A real group common to the resigned app/extensions is preferred. If the
	// signature has no usable group, emulate the missing entitlement in the
	// containing process exactly where classic sideload fixes do it.
	NSURL *realURL = preferredRealAppGroupURL();
	return realURL ?: sideloadFallbackAppGroupURL();
}

NSDictionary *mappedApplicationGroupEntitlements(NSDictionary *entitlements) {
	if (![entitlements isKindOfClass:[NSDictionary class]]) {
		return entitlements;
	}

	// Do not require LSBundleProxy/SecTask to have found a real group before
	// exposing the original Meta aliases. Code often checks entitlements before
	// it ever asks NSFileManager for the URL.
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
	NSMutableDictionary *mapped = [groupContainerURLs isKindOfClass:[NSDictionary class]]
		? [groupContainerURLs mutableCopy]
		: [NSMutableDictionary dictionary];
	NSURL *target = aliasTargetURL();
	if (!target) {
		return [mapped copy];
	}

	// Preserve every real container returned by the OS. Only synthesize aliases
	// that are missing from the resigned process.
	for (NSString *alias in knownMetaAppGroupIdentifiers()) {
		if (mapped[alias] == nil) {
			mapped[alias] = target;
		}
	}
	return [mapped copy];
}

NSURL *getAppGroupPathIfExists(void) {
	return aliasTargetURL();
}
