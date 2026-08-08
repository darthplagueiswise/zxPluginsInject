#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdint.h>
#import <string.h>

#import "Header.h"

typedef void (*ZXMSHookFunctionFn)(void *symbol, void *replace, void **result);
typedef NSString *(*ZXForumMGPathProviderFn)(void);

static ZXForumMGPathProviderFn gOriginalForumMGPathProvider = NULL;
static dispatch_once_t gForumMGHookOnce;

static BOOL zxIsReadableV2ParamsMap(NSString *path) {
	if (path.length == 0 || ![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
		return NO;
	}
	NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
	if (!handle) {
		return NO;
	}
	NSData *prefix = [handle readDataOfLength:3];
	[handle closeFile];
	if (prefix.length != 3) {
		return NO;
	}
	const uint8_t *bytes = (const uint8_t *)prefix.bytes;
	return bytes[0] == 'v' && bytes[1] == '2' && bytes[2] == ',';
}

static void zxAppendMapCandidate(NSMutableArray<NSString *> *candidates, NSString *path) {
	if (path.length > 0 && ![candidates containsObject:path]) {
		[candidates addObject:path];
	}
}

static void zxAppendMapsUnderContainer(NSMutableArray<NSString *> *candidates, NSURL *containerURL) {
	if (!containerURL.isFileURL) {
		return;
	}
	NSString *mobileConfigRoot = [containerURL.path stringByAppendingPathComponent:@"mobileconfig"];
	zxAppendMapCandidate(candidates, [[mobileConfigRoot stringByAppendingPathComponent:@"sessionless.data"] stringByAppendingPathComponent:@"params_map.txt"]);

	NSError *error = nil;
	NSArray<NSString *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:mobileConfigRoot error:&error];
	if (!children || error) {
		return;
	}
	for (NSString *child in children) {
		if (![child hasSuffix:@".data"] || [child isEqualToString:@"sessionless.data"]) {
			continue;
		}
		zxAppendMapCandidate(candidates, [[[mobileConfigRoot stringByAppendingPathComponent:child] stringByAppendingPathComponent:@"params_map.txt"] copy]);
	}
}

static NSString *zxFindForumRuntimeParamsMap(void) {
	NSMutableArray<NSString *> *candidates = [NSMutableArray array];

	// Preferred path: the genuine shared App Group selected from the signature.
	zxAppendMapsUnderContainer(candidates, preferredRealAppGroupURL());

	NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *documentsPath = documents.firstObject;
	if (documentsPath.length > 0) {
		// Forum legitimately maintains a local sessionless MobileConfig store.
		zxAppendMapCandidate(candidates, [[[documentsPath stringByAppendingPathComponent:@"mobileconfig"]
			stringByAppendingPathComponent:@"sessionless.data"]
			stringByAppendingPathComponent:@"params_map.txt"]);

		// Compatibility with the historical Documents/AppGroup emulation.
		zxAppendMapCandidate(candidates, [[[[documentsPath stringByAppendingPathComponent:@"AppGroup"]
			stringByAppendingPathComponent:@"mobileconfig"]
			stringByAppendingPathComponent:@"sessionless.data"]
			stringByAppendingPathComponent:@"params_map.txt"]);
	}

	// Last resort: the named v2 map packaged with this Forum build. The original
	// Forum parser still consumes it, so updatedHash_/updatedList_ are populated
	// by Forum itself rather than by synthetic UI values.
	NSString *bundleMap = [[[[NSBundle mainBundle] bundlePath]
		stringByAppendingPathComponent:@"params_maps"]
		stringByAppendingPathComponent:@"params_map.txt"];
	zxAppendMapCandidate(candidates, bundleMap);

	for (NSString *candidate in candidates) {
		if (zxIsReadableV2ParamsMap(candidate)) {
			return candidate;
		}
	}
	return nil;
}

static NSString *zxForumMGPathProvider(void) {
	NSString *originalPath = gOriginalForumMGPathProvider ? gOriginalForumMGPathProvider() : nil;
	if (zxIsReadableV2ParamsMap(originalPath)) {
		return originalPath;
	}
	return zxFindForumRuntimeParamsMap();
}

static ZXMSHookFunctionFn zxResolveMSHookFunction(void) {
	ZXMSHookFunctionFn hook = (ZXMSHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");
	if (hook) {
		return hook;
	}

	uint32_t imageCount = _dyld_image_count();
	for (uint32_t i = 0; i < imageCount; i++) {
		const char *name = _dyld_get_image_name(i);
		if (!name || !strstr(name, "CydiaSubstrate.framework/CydiaSubstrate")) {
			continue;
		}
		void *handle = dlopen(name, RTLD_NOW | RTLD_GLOBAL);
		if (handle) {
			hook = (ZXMSHookFunctionFn)dlsym(handle, "MSHookFunction");
			if (hook) {
				return hook;
			}
		}
	}
	return NULL;
}

static BOOL zxMatchesForumMGProvider(const uint8_t *target) {
	if (!target) {
		return NO;
	}
	uint32_t instruction0 = 0;
	uint32_t instruction1 = 0;
	uint32_t instruction3 = 0;
	memcpy(&instruction0, target + 0, sizeof(instruction0));
	memcpy(&instruction1, target + 4, sizeof(instruction1));
	memcpy(&instruction3, target + 12, sizeof(instruction3));

	// Forum build supplied with this project:
	//   stp x29, x30, [sp,#-0x10]!
	//   mov x29, sp
	//   bl  <XPlugins data-pair resolver>
	//   cbz x0, <return nil>
	return instruction0 == 0xA9BF7BFD &&
		instruction1 == 0x910003FD &&
		instruction3 == 0xB4000080;
}

static void zxInstallForumMGProviderFix(void) {
	dispatch_once(&gForumMGHookOnce, ^{
		if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.facebook.agora"]) {
			return;
		}

		ZXMSHookFunctionFn hookFunction = zxResolveMSHookFunction();
		const struct mach_header *mainHeader = _dyld_get_image_header(0);
		if (!hookFunction || !mainHeader) {
			return;
		}

		// Static analysis of the supplied Forum executable: the XPlugins-backed
		// updated-map path provider is Forum + 0x7EA40. Its data pair 0x47B11AF0
		// resolves to a compiled nil stub in this IPA. Verify the instructions
		// before patching so a different Forum build is never hooked blindly.
		uint8_t *target = (uint8_t *)mainHeader + 0x7EA40;
		if (!zxMatchesForumMGProvider(target)) {
			return;
		}

		hookFunction((void *)target, (void *)zxForumMGPathProvider, (void **)&gOriginalForumMGPathProvider);
	});
}

__attribute__((constructor)) static void zxForumMGPathFixInit(void) {
	zxInstallForumMGProviderFix();
}
