#import <dlfcn.h>
#import <objc/runtime.h>
#import "Header.h"

@interface METAAppGroup : NSObject
- (NSURL *)containerURL;
@end

@interface FBMobileConfigAdvancedSettingsViewController : NSObject
- (NSString *)getParamsMapPath:(NSString *)resourceName;
- (id)_cellForSchemaSection:(NSInteger)section forTableView:(id)tableView;
@end

static BOOL zxParseV2ParamsMapAtPath(NSString *path, NSString **hashOut, NSArray<NSString *> **paramsOut) {
	if (path.length == 0 || ![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
		return NO;
	}

	NSError *error = nil;
	NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
	if (contents.length == 0 || error) {
		return NO;
	}

	NSArray<NSString *> *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
	if (lines.count < 2) {
		return NO;
	}

	NSString *header = [lines.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSArray<NSString *> *headerFields = [header componentsSeparatedByString:@","];
	if (headerFields.count < 3 || ![headerFields[0] isEqualToString:@"v2"] || [headerFields[1] length] == 0) {
		return NO;
	}

	NSMutableArray<NSString *> *params = [NSMutableArray array];
	for (NSUInteger index = 1; index < lines.count; index++) {
		NSString *line = [lines[index] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
		if ([line isEqualToString:@"END"]) {
			break;
		}
		if (line.length == 0 || [line hasPrefix:@"*"]) {
			continue;
		}
		[params addObject:line];
	}

	if (params.count == 0) {
		return NO;
	}

	if (hashOut) {
		*hashOut = [headerFields[1] copy];
	}
	if (paramsOut) {
		*paramsOut = [params copy];
	}
	return YES;
}

static void zxAppendRuntimeMapCandidate(NSMutableArray<NSString *> *candidates, NSString *path) {
	if (path.length > 0 && ![candidates containsObject:path]) {
		[candidates addObject:path];
	}
}

static void zxAppendRuntimeMapsFromContainer(NSMutableArray<NSString *> *candidates, NSURL *containerURL) {
	if (!containerURL.isFileURL || containerURL.path.length == 0) {
		return;
	}

	NSString *mobileConfigRoot = [containerURL.path stringByAppendingPathComponent:@"mobileconfig"];
	zxAppendRuntimeMapCandidate(candidates, [[mobileConfigRoot stringByAppendingPathComponent:@"sessionless.data"] stringByAppendingPathComponent:@"params_map.txt"]);

	NSError *error = nil;
	NSArray<NSString *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:mobileConfigRoot error:&error];
	if (!children || error) {
		return;
	}
	for (NSString *child in children) {
		if (![child hasSuffix:@".data"] || [child isEqualToString:@"sessionless.data"]) {
			continue;
		}
		zxAppendRuntimeMapCandidate(candidates, [[[mobileConfigRoot stringByAppendingPathComponent:child]
			stringByAppendingPathComponent:@"params_map.txt"] copy]);
	}
}

static NSString *zxFindForumMGParamsMap(void) {
	NSMutableArray<NSString *> *candidates = [NSMutableArray array];

	zxAppendRuntimeMapsFromContainer(candidates, preferredRealAppGroupURL());

	NSArray<NSString *> *documentsURLs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsPath = documentsURLs.firstObject;
	if (documentsPath.length > 0) {
		zxAppendRuntimeMapCandidate(candidates, [[[[documentsPath stringByAppendingPathComponent:@"mobileconfig"]
			stringByAppendingPathComponent:@"sessionless.data"]
			stringByAppendingPathComponent:@"params_map.txt"] copy]);

		zxAppendRuntimeMapCandidate(candidates, [[[[[documentsPath stringByAppendingPathComponent:@"AppGroup"]
			stringByAppendingPathComponent:@"mobileconfig"]
			stringByAppendingPathComponent:@"sessionless.data"]
			stringByAppendingPathComponent:@"params_map.txt"] copy]);
	}

	zxAppendRuntimeMapCandidate(candidates, [[[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:@"params_maps"]
		stringByAppendingPathComponent:@"params_map.txt"]);

	for (NSString *candidate in candidates) {
		NSString *hash = nil;
		NSArray<NSString *> *params = nil;
		if (zxParseV2ParamsMapAtPath(candidate, &hash, &params)) {
			return candidate;
		}
	}
	return nil;
}

static BOOL zxReadForumMGSchema(NSString **hashOut, NSArray<NSString *> **paramsOut) {
	NSString *path = zxFindForumMGParamsMap();
	return zxParseV2ParamsMapAtPath(path, hashOut, paramsOut);
}

typedef void (*ZXObjcStoreStrongFn)(void **slot, void *value);

static BOOL zxSetStrongObjectIvar(id object, const char *name, id value) {
	if (!object || !name) {
		return NO;
	}
	Ivar ivar = class_getInstanceVariable([object class], name);
	if (!ivar || ivar_getTypeEncoding(ivar)[0] != '@') {
		return NO;
	}

	static ZXObjcStoreStrongFn storeStrong = NULL;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		storeStrong = (ZXObjcStoreStrongFn)dlsym(RTLD_DEFAULT, "objc_storeStrong");
	});
	if (!storeStrong) {
		return NO;
	}

	ptrdiff_t offset = ivar_getOffset(ivar);
	uint8_t *base = (uint8_t *)(__bridge void *)object;
	void **slot = (void **)(base + offset);
	void *rawValue = (__bridge void *)value;
	storeStrong(slot, rawValue);
	return YES;
}

static void zxPopulateForumMGSchema(id controller) {
	if (!controller) {
		return;
	}

	Ivar hashIvar = class_getInstanceVariable([controller class], "updatedHash_");
	Ivar listIvar = class_getInstanceVariable([controller class], "updatedList_");
	if (!hashIvar || !listIvar) {
		return;
	}

	id existingHash = object_getIvar(controller, hashIvar);
	id existingList = object_getIvar(controller, listIvar);
	if ([existingHash isKindOfClass:[NSString class]] && [existingHash length] > 0 &&
		[existingList respondsToSelector:@selector(count)] && [existingList count] > 0) {
		return;
	}

	NSString *hash = nil;
	NSArray<NSString *> *params = nil;
	if (!zxReadForumMGSchema(&hash, &params)) {
		return;
	}

	zxSetStrongObjectIvar(controller, "updatedHash_", hash);
	zxSetStrongObjectIvar(controller, "updatedList_", params);
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

	NSString *fileName = resourceName.pathExtension.length > 0
		? resourceName
		: [resourceName stringByAppendingPathExtension:@"txt"];
	NSString *candidate = [[[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:@"params_maps"]
		stringByAppendingPathComponent:fileName];
	return [[NSFileManager defaultManager] fileExistsAtPath:candidate] ? candidate : path;
}

- (id)_cellForSchemaSection:(NSInteger)section forTableView:(id)tableView {
	zxPopulateForumMGSchema(self);
	return %orig(section, tableView);
}
%end

%ctor {
	initializeAppGroupMapping();
	%init;
}
