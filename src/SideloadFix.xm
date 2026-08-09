#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

#import "Header.h"

@interface METAAppGroup : NSObject
- (NSURL *)containerURL;
@end

@interface FBMobileConfigAdvancedSettingsViewController : NSObject
- (NSString *)getParamsMapPath:(NSString *)resourceName;
@end

@interface FBMobileConfigLifeCycleController : NSObject
+ (const char *)getParamsMapPath:(NSInteger)unitType enableV4Resource:(BOOL)enableV4Resource;
+ (const char *)getRNParamsMapPath:(NSInteger)unitType;
@end

static BOOL zxFileIsReadableAndNonEmpty(NSString *path) {
	if (path.length == 0) {
		return NO;
	}
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
	return [attrs[NSFileType] isEqualToString:NSFileTypeRegular] && [attrs[NSFileSize] unsignedLongLongValue] > 0;
}

static BOOL zxIsV2TextMap(NSString *path) {
	if (!zxFileIsReadableAndNonEmpty(path)) {
		return NO;
	}
	NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
	NSData *prefix = [handle readDataOfLength:3];
	[handle closeFile];
	if (prefix.length != 3) {
		return NO;
	}
	const unsigned char *bytes = (const unsigned char *)prefix.bytes;
	return bytes[0] == 'v' && bytes[1] == '2' && bytes[2] == ',';
}

static NSArray<NSString *> *zxBundleResourceDirectories(void) {
	NSString *bundlePath = [NSBundle mainBundle].bundlePath;
	if (bundlePath.length == 0) {
		return @[];
	}
	return @[
		[bundlePath stringByAppendingPathComponent:@"mobileconfig_res"],
		[bundlePath stringByAppendingPathComponent:@"params_maps"],
		bundlePath,
	];
}

static NSString *zxFindBundleResourceFile(NSString *fileName, BOOL requireV2Text) {
	if (fileName.length == 0) {
		return nil;
	}
	for (NSString *directory in zxBundleResourceDirectories()) {
		NSString *candidate = [directory stringByAppendingPathComponent:fileName];
		BOOL valid = requireV2Text ? zxIsV2TextMap(candidate) : zxFileIsReadableAndNonEmpty(candidate);
		if (valid) {
			return candidate;
		}
	}
	return nil;
}

static void zxAppendRNMapCandidatesFromContainer(NSMutableArray<NSString *> *candidates, NSURL *containerURL) {
	if (!containerURL.isFileURL || containerURL.path.length == 0) {
		return;
	}
	NSString *root = [containerURL.path stringByAppendingPathComponent:@"mobileconfig"];
	NSArray<NSString *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];

	NSString *sessionless = [[root stringByAppendingPathComponent:@"sessionless.data"] stringByAppendingPathComponent:@"rn_params_map.txt"];
	if (![candidates containsObject:sessionless]) {
		[candidates addObject:sessionless];
	}
	for (NSString *child in children ?: @[]) {
		if (![child hasSuffix:@".data"] || [child isEqualToString:@"sessionless.data"]) {
			continue;
		}
		NSString *candidate = [[root stringByAppendingPathComponent:child] stringByAppendingPathComponent:@"rn_params_map.txt"];
		if (![candidates containsObject:candidate]) {
			[candidates addObject:candidate];
		}
	}
}

static NSString *zxFindRealRNParamsMap(void) {
	// RN metadata is a distinct v2 map. Never substitute params_map.txt here:
	// Facebook demonstrates that MG and PMAP can legitimately have different
	// counts even when their hashes share the same base/delta pair.
	NSMutableArray<NSString *> *candidates = [NSMutableArray array];
	NSString *bundleRN = zxFindBundleResourceFile(@"rn_params_map.txt", YES);
	if (bundleRN) {
		[candidates addObject:bundleRN];
	}

	zxAppendRNMapCandidatesFromContainer(candidates, preferredRealAppGroupURL());
	zxAppendRNMapCandidatesFromContainer(candidates, sideloadFallbackAppGroupURL());

	NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsPath = documents.firstObject;
	if (documentsPath.length > 0) {
		NSString *local = [[[documentsPath stringByAppendingPathComponent:@"mobileconfig"]
			stringByAppendingPathComponent:@"sessionless.data"]
			stringByAppendingPathComponent:@"rn_params_map.txt"];
		if (![candidates containsObject:local]) {
			[candidates addObject:local];
		}
	}

	for (NSString *candidate in candidates) {
		if (zxIsV2TextMap(candidate)) {
			return candidate;
		}
	}
	return nil;
}

static const char *zxStableFileSystemRepresentation(NSString *path) {
	if (path.length == 0) {
		return NULL;
	}
	static NSMutableDictionary<NSString *, NSValue *> *cache = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		cache = [NSMutableDictionary dictionary];
	});
	@synchronized (cache) {
		NSValue *existing = cache[path];
		if (existing) {
			return (const char *)existing.pointerValue;
		}
		const char *fs = path.fileSystemRepresentation;
		if (!fs) {
			return NULL;
		}
		char *copy = strdup(fs);
		if (!copy) {
			return NULL;
		}
		cache[path] = [NSValue valueWithPointer:copy];
		return copy;
	}
}

static BOOL zxCStringPathIsUsable(const char *path) {
	if (!path || path[0] == '\0') {
		return NO;
	}
	NSString *stringPath = [NSString stringWithUTF8String:path];
	return zxFileIsReadableAndNonEmpty(stringPath);
}

static NSString *zxFindParamsMapFallback(NSInteger unitType, BOOL enableV4Resource) {
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	if (enableV4Resource) {
		if (unitType == 4) {
			[names addObject:@"params_map_v4_u4.txt"];
		} else {
			[names addObject:@"params_map_v4_u0.txt"];
			[names addObject:[NSString stringWithFormat:@"params_map_v4_u%ld.txt", (long)unitType]];
		}
	} else {
		if (unitType == 4) {
			[names addObject:@"params_map_kMobileConfigAdminId.txt"];
		}
		[names addObject:@"params_map.txt"];
	}

	for (NSString *name in names) {
		NSString *candidate = zxFindBundleResourceFile(name, NO);
		if (candidate) {
			return candidate;
		}
	}
	return nil;
}

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
	if (URL || groupIdentifier == nil) {
		return URL;
	}

	// Preserve every group that the resigned process can genuinely resolve.
	// Only failed entitlement lookups are remapped. This is universal and does
	// not depend on a product bundle ID.
	if (isMetaAppGroupIdentifier(groupIdentifier)) {
		return preferredRealAppGroupURL() ?: sideloadFallbackAppGroupURL();
	}

	// Match the classic sideload AppGroup fix for otherwise-unavailable groups,
	// while never overriding a successful OS-provided container above.
	return sideloadFallbackAppGroupURL();
}
%end

%hook METAAppGroup
- (NSURL *)containerURL {
	NSURL *URL = %orig;
	return URL ?: getAppGroupPathIfExists();
}
%end

%hook NSUserDefaults
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (!isMetaAppGroupIdentifier(suiteName) || container != nil) {
		return %orig(suiteName, container);
	}
	NSURL *mappedContainer = preferredRealAppGroupURL() ?: sideloadFallbackAppGroupURL();
	return %orig(suiteName, mappedContainer);
}
%end

%hook NSBundle
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)extension inDirectory:(NSString *)subpath {
	NSString *path = %orig(name, extension, subpath);
	if (path.length > 0 || ![subpath isEqualToString:@"mobileconfig_res"]) {
		return path;
	}

	// Some repackaged Meta IPAs carry the same resources under params_maps.
	// Alias only this exact missing resource directory; leave every other
	// NSBundle lookup untouched.
	NSString *fallback = %orig(name, extension, @"params_maps");
	return fallback.length > 0 ? fallback : path;
}

- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)extension subdirectory:(NSString *)subpath {
	NSURL *URL = %orig(name, extension, subpath);
	if (URL || ![subpath isEqualToString:@"mobileconfig_res"]) {
		return URL;
	}
	return %orig(name, extension, @"params_maps");
}
%end

%hook FBMobileConfigAdvancedSettingsViewController
- (NSString *)getParamsMapPath:(NSString *)resourceName {
	NSString *path = %orig(resourceName);
	if (path.length > 0 || resourceName.length == 0) {
		return path;
	}

	NSString *fileName = resourceName.pathExtension.length > 0
		? resourceName
		: [resourceName stringByAppendingPathExtension:@"txt"];
	return zxFindBundleResourceFile(fileName, NO);
}
%end

%hook FBMobileConfigLifeCycleController
+ (const char *)getParamsMapPath:(NSInteger)unitType enableV4Resource:(BOOL)enableV4Resource {
	const char *path = %orig(unitType, enableV4Resource);
	if (zxCStringPathIsUsable(path)) {
		return path;
	}
	return zxStableFileSystemRepresentation(zxFindParamsMapFallback(unitType, enableV4Resource));
}

+ (const char *)getRNParamsMapPath:(NSInteger)unitType {
	const char *path = %orig(unitType);
	if (zxCStringPathIsUsable(path)) {
		return path;
	}
	return zxStableFileSystemRepresentation(zxFindRealRNParamsMap());
}
%end

%ctor {
	initializeAppGroupMapping();
	%init;
}
