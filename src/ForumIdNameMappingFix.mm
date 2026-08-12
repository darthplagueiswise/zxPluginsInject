#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>

#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>

#import "Header.h"

@interface FBMobileConfigAdvancedSettingsViewController : NSObject
- (id)initWithSessionManager:(id)sessionManager
          sessionlessManager:(id)sessionlessManager
              adminIdManager:(id)adminIdManager
              displayOptions:(id)displayOptions;
@end

namespace {

using ZXUnitMap = std::unordered_map<int, int>;
using ZXParsedMetaList = std::shared_ptr<const void>;
using ZXMakeConfigMetaListWithMergeFn = ZXParsedMetaList (*)(
	int,
	const void *,
	int,
	const char *,
	ZXUnitMap &,
	std::string &,
	bool
);
using ZXSharedPtrMoveFn = void *(*)(void *, void *);
using ZXStringMoveFn = void *(*)(void *, void *);
using ZXHashMergeFn = std::string (*)(const std::string &, const std::string &);

static BOOL zxIsExpectedForumProcess(void) {
	return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.agora"] &&
		[[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"1029615221"];
}

static BOOL zxMainImageHasExpectedUUID(const struct mach_header_64 *header) {
	if (!header || header->magic != MH_MAGIC_64) return NO;

	static const uint8_t expectedUUID[16] = {
		0x4c, 0x4c, 0x44, 0x66, 0x55, 0x55, 0x31, 0x44,
		0xa1, 0xaa, 0xd3, 0x35, 0x2a, 0xab, 0x60, 0x4c
	};
	const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header + 1);
	for (uint32_t index = 0; index < header->ncmds; index++) {
		const auto *command = reinterpret_cast<const struct load_command *>(cursor);
		if (command->cmdsize < sizeof(struct load_command)) return NO;
		if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
			const auto *uuidCommand = reinterpret_cast<const struct uuid_command *>(command);
			return std::memcmp(uuidCommand->uuid, expectedUUID, sizeof(expectedUUID)) == 0;
		}
		cursor += command->cmdsize;
	}
	return NO;
}

static uint8_t *zxExpectedForumImageBase(void) {
	if (!zxIsExpectedForumProcess()) return nullptr;
	const struct mach_header *rawHeader = _dyld_get_image_header(0);
	if (!rawHeader || rawHeader->magic != MH_MAGIC_64) return nullptr;
	auto *header = reinterpret_cast<const struct mach_header_64 *>(rawHeader);
	return zxMainImageHasExpectedUUID(header) ? reinterpret_cast<uint8_t *>(const_cast<struct mach_header *>(rawHeader)) : nullptr;
}

static BOOL zxWordsMatch(uint8_t *base, uintptr_t offset, const uint32_t expected[4]) {
	if (!base) return NO;
	uint32_t actual[4] = {};
	std::memcpy(actual, base + offset, sizeof(actual));
	return std::memcmp(actual, expected, sizeof(actual)) == 0;
}

static BOOL zxValidateForumParserABI(uint8_t *base) {
	// Fail closed: these are the first four instructions of the four native
	// routines called by the original initializer in Forum 19.0 build
	// 1029615221. A different binary never receives version-specific calls.
	static const uint32_t parserWords[4] = {0xd10343ff, 0xa9095ff8, 0xa90a57f6, 0xa90b4ff4};
	static const uint32_t sharedPtrMoveWords[4] = {0xd100c3ff, 0xa9014ff4, 0xa9027bfd, 0x910083fd};
	static const uint32_t stringMoveWords[4] = {0xa9be4ff4, 0xa9017bfd, 0x910043fd, 0xaa0103f3};
	static const uint32_t hashMergeWords[4] = {0xd10183ff, 0xa90357f6, 0xa9044ff4, 0xa9057bfd};
	return zxWordsMatch(base, 0x268DA8, parserWords) &&
		zxWordsMatch(base, 0x0E96A0, sharedPtrMoveWords) &&
		zxWordsMatch(base, 0x0A82F4, stringMoveWords) &&
		zxWordsMatch(base, 0x0E8210, hashMergeWords);
}

static BOOL zxReadIndirectInt(uint8_t *base, uintptr_t globalOffset, int *valueOut) {
	if (!base || !valueOut) return NO;
	uint8_t *holder = *reinterpret_cast<uint8_t **>(base + globalOffset);
	if (!holder) return NO;
	*valueOut = *reinterpret_cast<int *>(holder + 8);
	return YES;
}

static NSString *zxForumIdNameMappingPath(void) {
	NSString *root = zxCanonicalForumAppGroupRoot();
	if (!root.length) return nil;
	zxSeedForumIdNameMappingIfNeeded(root);
	NSString *path = [[root stringByAppendingPathComponent:@"mobileconfig"]
		stringByAppendingPathComponent:@"id_name_mapping.json"];
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (!data.length) return nil;
	id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	return [value isKindOfClass:NSArray.class] && [(NSArray *)value count] > 0 ? path : nil;
}

static void zxPopulateForumIdNameSchema(id controller) {
	uint8_t *base = zxExpectedForumImageBase();
	if (!controller || !base || !zxValidateForumParserABI(base)) return;

	Ivar updatedHashIvar = class_getInstanceVariable([controller class], "updatedHash_");
	Ivar updatedListIvar = class_getInstanceVariable([controller class], "updatedList_");
	if (!updatedHashIvar || !updatedListIvar) return;
	const char *hashEncoding = ivar_getTypeEncoding(updatedHashIvar);
	const char *listEncoding = ivar_getTypeEncoding(updatedListIvar);
	if (!hashEncoding || !listEncoding ||
		!std::strstr(hashEncoding, "basic_string") ||
		!std::strstr(listEncoding, "shared_ptr")) {
		return;
	}

	uint8_t *objectBase = reinterpret_cast<uint8_t *>((__bridge void *)controller);
	void *updatedListStorage = objectBase + ivar_getOffset(updatedListIvar);
	void *updatedHashStorage = objectBase + ivar_getOffset(updatedHashIvar);
	if (*reinterpret_cast<void **>(updatedListStorage) != nullptr) return;

	NSString *mappingPath = zxForumIdNameMappingPath();
	NSError *readError = nil;
	NSString *mappingText = mappingPath.length
		? [NSString stringWithContentsOfFile:mappingPath encoding:NSUTF8StringEncoding error:&readError]
		: nil;
	if (readError || ![mappingText hasPrefix:@"["]) return;
	const char *mappingCString = mappingText.UTF8String;
	if (!mappingCString) return;

	uint8_t *schemaHolder = *reinterpret_cast<uint8_t **>(base + 0x3376BD0);
	uint8_t *countHolder = *reinterpret_cast<uint8_t **>(base + 0x3376BC8);
	uint8_t *nativeHashHolder = *reinterpret_cast<uint8_t **>(base + 0x33715C0);
	if (!schemaHolder || !countHolder || !nativeHashHolder) return;
	const void *compiledSchema = *reinterpret_cast<const void **>(schemaHolder + 0x10);
	int compiledCount = *reinterpret_cast<int *>(countHolder + 8);
	const char *nativeHashCString = *reinterpret_cast<const char **>(nativeHashHolder + 0x10);
	if (!compiledSchema || compiledCount <= 0 || compiledCount > 100000 ||
		!nativeHashCString || nativeHashCString[0] == '\0') {
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

	auto makeConfigMetaList = reinterpret_cast<ZXMakeConfigMetaListWithMergeFn>(base + 0x268DA8);
	auto moveSharedPtr = reinterpret_cast<ZXSharedPtrMoveFn>(base + 0x0E96A0);
	auto moveString = reinterpret_cast<ZXStringMoveFn>(base + 0x0A82F4);
	auto mergeHashes = reinterpret_cast<ZXHashMergeFn>(base + 0x0E8210);

	std::string parsedHash;
	ZXParsedMetaList parsedList = makeConfigMetaList(
		2,
		compiledSchema,
		compiledCount,
		mappingCString,
		unitMap,
		parsedHash,
		false
	);
	if (!parsedList || parsedHash.empty()) return;

	std::string nativeHash(nativeHashCString);
	std::string mergedHash = mergeHashes(nativeHash, parsedHash);
	if (mergedHash.empty()) return;

	moveSharedPtr(updatedListStorage, &parsedList);
	moveString(updatedHashStorage, &mergedHash);
	NSLog(@"[zx][forum-mobileconfig] populated native id/name schema from %@", mappingPath);
}

} // namespace

%hook FBMobileConfigAdvancedSettingsViewController

- (id)initWithSessionManager:(id)sessionManager
          sessionlessManager:(id)sessionlessManager
              adminIdManager:(id)adminIdManager
              displayOptions:(id)displayOptions {
	id result = %orig(sessionManager, sessionlessManager, adminIdManager, displayOptions);
	if (result) zxPopulateForumIdNameSchema(result);
	return result;
}

%end
