#import <stdlib.h>
#import "Header.h"

static NSString *gHomePath = nil;
static NSString *gDocumentsPath = nil;
static NSString *gAppGroupPath = nil;
static NSArray<NSArray<NSString *> *> *gRelocationRules = nil;  // @[ @[legacyPrefix, canonicalPrefix], ... ]
static dispatch_once_t gPathConstantsOnce;
static __thread BOOL gCanonicalizingSideloadPath = NO;

// Subdirectories that must live inside the fake App Group container.
// "mobileconfig_qce" is a sibling of "mobileconfig", not a child: a plain
// prefix test on "mobileconfig" never matches it, because the character that
// follows the prefix is '_' and not '/' or NUL. It comes from the same
// MobileConfig manager (bufferPathPostfix="qce"), same base directory.
static NSString *const kRelocatedLeaves[] = { @"mobileconfig", @"mobileconfig_qce" };
static const NSUInteger kRelocatedLeafCount = sizeof(kRelocatedLeaves) / sizeof(kRelocatedLeaves[0]);

// /var and /private/var are the same volume; /var is a symlink to /private/var.
// getenv("HOME") and NSHomeDirectory() hand back the /var form, but anything
// that has been through realpath(), std::filesystem::canonical() or
// -[NSURL fileSystemRepresentation] can come back as /private/var. Both sides
// of every prefix comparison go through this so the two forms unify.
NSString *standardizedSideloadPath(NSString *path) {
	if (path.length < 13) return path;  // strlen("/private/var/")
	if ([path hasPrefix:@"/private/var/"] || [path hasPrefix:@"/private/tmp/"]) {
		return [path substringFromIndex:8];
	}
	return path;
}

static void initializePathConstants(void) {
	dispatch_once(&gPathConstantsOnce, ^{
		const char *homeCString = getenv("HOME");
		NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
		if (home.length == 0) home = NSHomeDirectory();
		gHomePath = [standardizedSideloadPath(home) copy];
		gDocumentsPath = [[gHomePath stringByAppendingPathComponent:@"Documents"] copy];
		gAppGroupPath = [[gDocumentsPath stringByAppendingPathComponent:@"AppGroup"] copy];

		NSMutableArray<NSArray<NSString *> *> *rules = [NSMutableArray array];
		for (NSUInteger i = 0; i < kRelocatedLeafCount; i++) {
			NSString *leaf = kRelocatedLeaves[i];
			NSString *canonical = [gAppGroupPath stringByAppendingPathComponent:leaf];
			[rules addObject:@[[gHomePath stringByAppendingPathComponent:leaf], canonical]];
			[rules addObject:@[[gDocumentsPath stringByAppendingPathComponent:leaf], canonical]];
		}
		gRelocationRules = [rules copy];
	});
}

BOOL createDirectoryIfNotExists(NSString *path) {
	if (path.length == 0) return NO;
	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL isDirectory = NO;
	if ([fm fileExistsAtPath:path isDirectory:&isDirectory]) return isDirectory;
	NSError *error = nil;
	BOOL created = [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
	return created && error == nil;
}

// Deliberately NOT dispatch_once. A dispatch_once here caches failure as well
// as success: if the container directory is missing on the very first call,
// every later call returns nil for the lifetime of the process, the
// NSFileManager hook falls through to %orig, %orig returns nil (the app is not
// entitled to the group it asked for), and hosts that cache their own app group
// lookup - METAAppGroup in the Meta apps does exactly this, behind its own
// dispatch_once - keep that nil forever. Retrying until the directory exists
// costs one stat on the happy path.
NSURL *getAppGroupPathIfExists(void) {
	static NSURL *cached = nil;
	static dispatch_once_t constantsOnce;
	dispatch_once(&constantsOnce, ^{ initializePathConstants(); });
	if (cached) return cached;
	if (!createDirectoryIfNotExists(gAppGroupPath)) return nil;
	@synchronized ([NSURL class]) {
		if (!cached) cached = [NSURL fileURLWithPath:gAppGroupPath isDirectory:YES];
	}
	return cached;
}

static BOOL pathIsEqualToOrInsidePath(NSString *path, NSString *prefix) {
	if (path.length == 0 || prefix.length == 0) return NO;
	if ([path isEqualToString:prefix]) return YES;
	return [path hasPrefix:[prefix stringByAppendingString:@"/"]];
}

NSString *canonicalizedSideloadPath(NSString *path) {
	if (path.length == 0 || gCanonicalizingSideloadPath) return path;
	gCanonicalizingSideloadPath = YES;
	initializePathConstants();
	NSString *standardized = standardizedSideloadPath(path);
	NSString *result = path;
	for (NSArray<NSString *> *rule in gRelocationRules) {
		NSString *legacyPrefix = rule[0];
		if (!pathIsEqualToOrInsidePath(standardized, legacyPrefix)) continue;
		NSString *suffix = [standardized substringFromIndex:legacyPrefix.length];
		if ([suffix hasPrefix:@"/"]) suffix = [suffix substringFromIndex:1];
		result = suffix.length == 0 ? rule[1] : [rule[1] stringByAppendingPathComponent:suffix];
		break;
	}
	gCanonicalizingSideloadPath = NO;
	return result;
}

NSURL *canonicalizedSideloadURL(NSURL *url) {
	if (!url || !url.isFileURL) return url;
	NSString *canonicalPath = canonicalizedSideloadPath(url.path);
	if ([canonicalPath isEqualToString:url.path]) return url;
	return [NSURL fileURLWithPath:canonicalPath isDirectory:url.hasDirectoryPath];
}

static NSDate *modificationDateForPath(NSFileManager *fm, NSString *path) {
	return [fm attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

static BOOL mergeLegacyItem(NSFileManager *fm, NSString *sourcePath, NSString *destinationPath) {
	BOOL sourceIsDirectory = NO;
	if (![fm fileExistsAtPath:sourcePath isDirectory:&sourceIsDirectory]) return YES;
	BOOL destinationIsDirectory = NO;
	BOOL destinationExists = [fm fileExistsAtPath:destinationPath isDirectory:&destinationIsDirectory];
	if (!destinationExists) {
		if (!createDirectoryIfNotExists([destinationPath stringByDeletingLastPathComponent])) return NO;
		NSError *error = nil;
		return [fm moveItemAtPath:sourcePath toPath:destinationPath error:&error] && error == nil;
	}
	if (sourceIsDirectory && destinationIsDirectory) {
		NSError *error = nil;
		NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:sourcePath error:&error];
		if (!children || error) return NO;
		BOOL merged = YES;
		for (NSString *child in children) {
			if (!mergeLegacyItem(fm, [sourcePath stringByAppendingPathComponent:child], [destinationPath stringByAppendingPathComponent:child])) merged = NO;
		}
		if (merged) [fm removeItemAtPath:sourcePath error:nil];
		return merged;
	}
	if (!sourceIsDirectory && !destinationIsDirectory) {
		NSDate *sourceDate = modificationDateForPath(fm, sourcePath);
		NSDate *destinationDate = modificationDateForPath(fm, destinationPath);
		BOOL sourceIsNewer = sourceDate && (!destinationDate || [sourceDate compare:destinationDate] == NSOrderedDescending);
		if (sourceIsNewer) {
			if (![fm removeItemAtPath:destinationPath error:nil]) return NO;
			NSError *error = nil;
			return [fm moveItemAtPath:sourcePath toPath:destinationPath error:&error] && error == nil;
		}
		[fm removeItemAtPath:sourcePath error:nil];
		return YES;
	}
	return NO;
}

// Every consumer we can enumerate gets routed to the canonical directory by
// canonicalizedSideloadPath / rewriteMobileConfigPath. But some call sites
// resolve which of the two candidate paths to use ("does the legacy path
// exist?" - a question our own __status hook answers as YES once data has been
// migrated there) and then keep using that literal legacy string for every
// following call, including ones we either cannot intercept (calls made from
// inside a system dylib's own shared-cache code, invisible to fishhook) or
// chose not to intercept (the directory_iterator constructor: on Apple's
// arm64 ABI a constructor returns `this` in x0, and a replacement that gets
// that wrong corrupts the caller's object pointer instead of crashing
// cleanly).
//
// Deleting the emptied legacy directory - what earlier revisions of this file
// did - turns every one of those literal-path calls into ENOENT. For a
// throwing API like the single-argument directory_iterator constructor that
// means an uncaught std::filesystem::filesystem_error and an abort.
//
// The fix that needs no interception at all: turn the (now empty) legacy
// directory into a symlink pointing at the canonical one. The kernel resolves
// the indirection for every syscall - open, opendir, mkdir, unlink, rename,
// realpath - regardless of which libc++ symbol issued it or whether we hooked
// that symbol. A literal legacy path becomes indistinguishable from the
// canonical one at the point every one of these APIs actually reads.
//
// The symlink check MUST use an API that does not itself follow symlinks.
// -[NSFileManager fileExistsAtPath:isDirectory:] calls stat(), which resolves
// the link and reports isDirectory=YES for it - on a second launch that would
// send the already-relocated legacy path straight back into mergeLegacyItem,
// which would list it (reading through the very link being tested), compare
// each entry against the identical file at the canonical path, and delete it
// as a merge "duplicate". destinationOfSymbolicLinkAtPath: uses lstat(), so it
// only succeeds when the path itself is a link and never follows it.
void migrateLegacyMobileConfigIfNeeded(void) {
	// Forum now gets the correct AppGroup root at the
	// FBMobileConfigInitParams boundary (MobileConfigSessionlessFix.xm).
	// Creating legacy symlinks here would make Documents/mobileconfig appear
	// again even when the manager no longer writes there, obscuring the device
	// verification and preserving the failed path-rewrite workaround.
	if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.agora"]) {
		return;
	}

	initializePathConstants();
	if (!getAppGroupPathIfExists()) return;
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSArray<NSString *> *rule in gRelocationRules) {
		NSString *legacyPath = rule[0];
		NSString *canonicalPath = rule[1];
		createDirectoryIfNotExists(canonicalPath);

		NSString *existingDestination = [fm destinationOfSymbolicLinkAtPath:legacyPath error:nil];
		if (existingDestination) {
			if (![existingDestination isEqualToString:canonicalPath]) {
				[fm removeItemAtPath:legacyPath error:nil];
				[fm createSymbolicLinkAtPath:legacyPath withDestinationPath:canonicalPath error:nil];
			}
			continue;  // already relocated on a previous launch - nothing left to merge
		}

		BOOL isDirectory = NO;
		if ([fm fileExistsAtPath:legacyPath isDirectory:&isDirectory] && isDirectory) {
			mergeLegacyItem(fm, legacyPath, canonicalPath);
		}
		if (![fm fileExistsAtPath:legacyPath]) {
			// Merge finished (or there was never anything here): safe to link.
			[fm createSymbolicLinkAtPath:legacyPath withDestinationPath:canonicalPath error:nil];
		}
		// else: a real file/directory is still there because the merge did
		// not fully succeed. Leave it alone - retried on the next launch.
	}
}
