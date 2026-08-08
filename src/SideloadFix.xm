#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>
#include <cstring>

#import "Header.h"

@interface METAAppGroup : NSObject
- (NSURL *)containerURL;
@end

@interface FBMobileConfigAdvancedSettingsViewController : NSObject
- (NSString *)getParamsMapPath:(NSString *)resourceName;
- (id)initWithSessionManager:(id)sessionManager
          sessionlessManager:(id)sessionlessManager
              adminIdManager:(id)adminIdManager
              displayOptions:(id)displayOptions;
@end

static BOOL zxIsForumProcess(void) {
	return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.facebook.agora"];
}

static BOOL zxMainImageHasExpectedForumUUID(const struct mach_header_64 *header) {
	if (!header || header->magic != MH_MAGIC_64) {
		return NO;
	}

	static const uint8_t expectedUUID[16] = {
		0x4c, 0x4c, 0x44, 0x66, 0x55, 0x55, 0x31, 0x44,
		0xa1, 0xaa, 0xd3, 0x35, 0x2a, 0xab, 0x60, 0x4c
	};

	const uint8_t *cursor = (const uint8_t *)(header + 1);
	for (uint32_t index = 0; index < header->ncmds; index++) {
		const struct load_command *command = (const struct load_command *)cursor;
		if (command->cmdsize < sizeof(struct load_command)) {
			return NO;
		}
		if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
			const struct uuid_command *uuidCommand = (const struct uuid_command *)command;
			return memcmp(uuidCommand->uuid, expectedUUID, sizeof(expectedUUID)) == 0;
		}
		cursor += command->cmdsize;
	}
	return NO;
}

static uint8_t *zxExpectedForumImageBase(void) {
	if (!zxIsForumProcess() || ![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"1029615221"]) {
		return NULL;
	}

	const struct mach_header *rawHeader = _dyld_get_image_header(0);
	if (!rawHeader || rawHeader->magic != MH_MAGIC_64) {
		return NULL;
	}
	const struct mach_header_64 *header = (const struct mach_header_64 *)rawHeader;
	return zxMainImageHasExpectedForumUUID(header) ? (uint8_t *)header : NULL;
}

static BOOL zxWordsMatch(uint8_t *base, uintptr_t offset, const uint32_t expected[4]) {
	if (!base) {
		return NO;
	}
	uint32_t actual[4] = {};
	memcpy(actual, base + offset, sizeof(actual));
	return memcmp(actual, expected, sizeof(actual)) == 0;
}

static BOOL zxValidateForumMobileConfigABI(uint8_t *base) {
	static const uint32_t parserWords[4] = {0xd10343ff, 0xa9095ff8, 0xa90a57f6, 0xa90b4ff4};
	static const uint32_t sharedPtrMoveWords[4] = {0xd100c3ff, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
	static const uint32_t stringMoveWords[4] = {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0103f3};
	static const uint32_t hashMergeWords[4] = {0xd10183ff, 0xa90357f6, 0xa9044ff4, 0xa9057bfd};
	return zxWordsMatch(base, 0x268DA8, parserWords) &&
		zxWordsMatch(base, 0x0E96A0, sharedPtrMoveWords) &&
		zxWordsMatch(base, 0x0A82F4, stringMoveWords) &&
		zxWordsMatch(base, 0x0E8210, hashMergeWords);
}

static BOOL zxIsV2ParamsMapText(NSString *contents) {
	return contents.length > 3 && [contents hasPrefix:@"v2,"];
}

static void zxAppendCandidate(NSMutableArray<NSString *> *candidates, NSString *path) {
	if (path.length > 0 && ![candidates containsObject:path]) {
		[candidates addObject:path];
	}
}

static void zxAppendMetadataCandidatesUnderContainer(NSMutableArray<NSString *> *candidates, NSURL *containerURL) {
	if (!containerURL.isFileURL || containerURL.path.length == 0) {
		return;
	}

	NSString *mobileConfigRoot = [containerURL.path stringByAppendingPathComponent:@"mobileconfig"];
	NSArray<NSString *> *preferredNames = @[@"rn_params_map.txt", @"params_map.txt"];
	for (NSString *name in preferredNames) {
		zxAppendCandidate(candidates, [[mobileConfigRoot stringByAppendingPathComponent:@"sessionless.data"] stringByAppendingPathComponent:name]);
	}

	NSError *error = nil;
	NSArray<NSString *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:mobileConfigRoot error:&error];
	if (!children || error) {
		return;
	}
	for (NSString *child in children) {
		if (![child hasSuffix:@".data"] || [child isEqualToString:@"sessionless.data"]) {
			continue;
		}
		for (NSString *name in preferredNames) {
			zxAppendCandidate(candidates, [[mobileConfigRoot stringByAppendingPathComponent:child] stringByAppendingPathComponent:name]);
		}
	}
}

static NSString *zxFindForumMergeMetadataPath(void) {
	NSMutableArray<NSString *> *candidates = [NSMutableArray array];

	zxAppendMetadataCandidatesUnderContainer(candidates, sideloadFallbackAppGroupURL());

	NSArray<NSString *> *documentsURLs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsPath = documentsURLs.firstObject;
	if (documentsPath.length > 0) {
		NSString *localRoot = [documentsPath stringByAppendingPathComponent:@"mobileconfig/sessionless.data"];
		zxAppendCandidate(candidates, [localRoot stringByAppendingPathComponent:@"rn_params_map.txt"]);
		zxAppendCandidate(candidates, [localRoot stringByAppendingPathComponent:@"params_map.txt"]);
	}

	NSURL *realGroup = preferredRealAppGroupURL();
	if (realGroup && ![realGroup isEqual:sideloadFallbackAppGroupURL()]) {
		zxAppendMetadataCandidatesUnderContainer(candidates, realGroup);
	}

	NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
	zxAppendCandidate(candidates, [[bundlePath stringByAppendingPathComponent:@"mobileconfig_res"] stringByAppendingPathComponent:@"rn_params_map.txt"]);
	zxAppendCandidate(candidates, [[bundlePath stringByAppendingPathComponent:@"params_maps"] stringByAppendingPathComponent:@"rn_params_map.txt"]);
	zxAppendCandidate(candidates, [[bundlePath stringByAppendingPathComponent:@"params_maps"] stringByAppendingPathComponent:@"params_map.txt"]);

	for (NSString *candidate in candidates) {
		NSError *error = nil;
		NSString *contents = [NSString stringWithContentsOfFile:candidate encoding:NSUTF8StringEncoding error:&error];
		if (!error && zxIsV2ParamsMapText(contents)) {
			return candidate;
		}
	}
	return nil;
}

using ZXUnitMap = std::unordered_map<int, int>;
using ZXParsedMetaList = std::shared_ptr<const void>;
using ZXMakeConfigMetaListWithMergeFn = ZXParsedMetaList (*)(int, const void *, int, const char *, ZXUnitMap &, std::string &, bool);
using ZXSharedPtrMoveFn = void *(*)(void *, void *);
using ZXStringMoveFn = void *(*)(void *, void *);
using ZXHashMergeFn = std::string (*)(const std::string &, const std::string &);

static BOOL zxReadIndirectInt(uint8_t *base, uintptr_t globalOffset, int *valueOut) {
	if (!base || !valueOut) {
		return NO;
	}
	uint8_t *holder = *(uint8_t **)(base + globalOffset);
	if (!holder) {
		return NO;
	}
	*valueOut = *(int *)(holder + 8);
	return YES;
}

static void zxPopulateForumMGSchemaWithOriginalParser(id controller) {
	if (!controller) {
		return;
	}

	uint8_t *base = zxExpectedForumImageBase();
	if (!base || !zxValidateForumMobileConfigABI(base)) {
		return;
	}

	Ivar updatedHashIvar = class_getInstanceVariable([controller class], "updatedHash_");
	Ivar updatedListIvar = class_getInstanceVariable([controller class], "updatedList_");
	if (!updatedHashIvar || !updatedListIvar) {
		return;
	}
	const char *hashEncoding = ivar_getTypeEncoding(updatedHashIvar);
	const char *listEncoding = ivar_getTypeEncoding(updatedListIvar);
	if (!hashEncoding || !listEncoding ||
		!strstr(hashEncoding, "basic_string") || !strstr(listEncoding, "shared_ptr")) {
		return;
	}

	uint8_t *objectBase = (uint8_t *)(__bridge void *)controller;
	void *updatedListStorage = objectBase + ivar_getOffset(updatedListIvar);
	void *updatedHashStorage = objectBase + ivar_getOffset(updatedHashIvar);
	void **listWords = (void **)updatedListStorage;
	if (listWords[0] != NULL) {
		return;
	}

	NSString *metadataPath = zxFindForumMergeMetadataPath();
	if (metadataPath.length == 0) {
		return;
	}
	NSError *readError = nil;
	NSString *metadataText = [NSString stringWithContentsOfFile:metadataPath encoding:NSUTF8StringEncoding error:&readError];
	if (readError || !zxIsV2ParamsMapText(metadataText)) {
		return;
	}
	const char *metadataCString = [metadataText UTF8String];
	if (!metadataCString) {
		return;
	}

	uint8_t *schemaHolder = *(uint8_t **)(base + 0x3376BD0);
	uint8_t *countHolder = *(uint8_t **)(base + 0x3376BC8);
	uint8_t *nativeHashHolder = *(uint8_t **)(base + 0x33715C0);
	if (!schemaHolder || !countHolder || !nativeHashHolder) {
		return;
	}
	const void *compiledSchema = *(const void **)(schemaHolder + 0x10);
	int compiledCount = *(int *)(countHolder + 8);
	const char *nativeHashCString = *(const char **)(nativeHashHolder + 0x10);
	if (!compiledSchema || compiledCount <= 0 || compiledCount > 100000 || !nativeHashCString || nativeHashCString[0] == '\0') {
		return;
	}

	int unit1 = 0, unit2 = 0, unit3 = 0, unit4 = 0;
	if (!zxReadIndirectInt(base, 0x3376BC0, &unit1) ||
		!zxReadIndirectInt(base, 0x3376BB8, &unit2) ||
		!zxReadIndirectInt(base, 0x3376BA8, &unit3) ||
		!zxReadIndirectInt(base, 0x3376BB0, &unit4)) {
		return;
	}

	ZXUnitMap unitMap;
	unitMap.emplace(1, unit1);
	unitMap.emplace(2, unit2);
	unitMap.emplace(3, unit3);
	unitMap.emplace(4, unit4);

	auto makeConfigMetaList = (ZXMakeConfigMetaListWithMergeFn)(base + 0x268DA8);
	auto moveSharedPtr = (ZXSharedPtrMoveFn)(base + 0x0E96A0);
	auto moveString = (ZXStringMoveFn)(base + 0x0A82F4);
	auto mergeHashes = (ZXHashMergeFn)(base + 0x0E8210);

	std::string parsedHash;
	ZXParsedMetaList parsedList = makeConfigMetaList(
		2,
		compiledSchema,
		compiledCount,
		metadataCString,
		unitMap,
		parsedHash,
		false);
	if (!parsedList || parsedHash.empty()) {
		return;
	}

	std::string nativeHash(nativeHashCString);
	std::string mergedHash = mergeHashes(nativeHash, parsedHash);
	if (mergedHash.empty()) {
		return;
	}

	moveSharedPtr(updatedListStorage, (void *)&parsedList);
	moveString(updatedHashStorage, (void *)&mergedHash);
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
	NSDictionary *mapped = mappedGroupContainerURLs(containerURLs);
	if (!zxIsForumProcess() || ![mapped isKindOfClass:[NSDictionary class]]) {
		return mapped;
	}

	NSURL *fallback = sideloadFallbackAppGroupURL();
	if (!fallback) {
		return mapped;
	}
	NSMutableDictionary *forumMapped = [mapped mutableCopy];
	for (NSString *key in [mapped allKeys]) {
		if (isMetaAppGroupIdentifier(key)) {
			forumMapped[key] = fallback;
		}
	}
	return [forumMapped copy];
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	if (zxIsForumProcess() && groupIdentifier != nil) {
		return sideloadFallbackAppGroupURL();
	}

	NSURL *URL = %orig(groupIdentifier);
	if (URL || !isMetaAppGroupIdentifier(groupIdentifier)) {
		return URL;
	}
	URL = preferredRealAppGroupURL();
	return URL ?: sideloadFallbackAppGroupURL();
}
%end

%hook METAAppGroup
- (NSURL *)containerURL {
	if (zxIsForumProcess()) {
		return sideloadFallbackAppGroupURL();
	}
	NSURL *URL = %orig;
	return URL ?: getAppGroupPathIfExists();
}
%end

%hook NSUserDefaults
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (!isMetaAppGroupIdentifier(suiteName)) {
		return %orig(suiteName, container);
	}
	NSURL *mappedContainer = zxIsForumProcess() ? sideloadFallbackAppGroupURL() : preferredRealAppGroupURL();
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

- (id)initWithSessionManager:(id)sessionManager
          sessionlessManager:(id)sessionlessManager
              adminIdManager:(id)adminIdManager
              displayOptions:(id)displayOptions {
	id result = %orig(sessionManager, sessionlessManager, adminIdManager, displayOptions);
	if (result) {
		zxPopulateForumMGSchemaWithOriginalParser(result);
	}
	return result;
}
%end

%ctor {
	initializeAppGroupMapping();
	%init;
}
