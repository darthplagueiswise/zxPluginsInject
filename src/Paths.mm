#import <objc/runtime.h>
#import <stdlib.h>

#import "Header.h"

static NSString *gHomePath = nil;
static NSString *gDocumentsPath = nil;
static NSString *gAppGroupPath = nil;
static NSString *gHomeMobileConfigPath = nil;
static NSString *gDocumentsMobileConfigPath = nil;
static NSString *gCanonicalMobileConfigPath = nil;
static dispatch_once_t gPathConstantsOnce;
static __thread BOOL gCanonicalizingSideloadPath = NO;

static void initializePathConstants() {
	dispatch_once(&gPathConstantsOnce, ^{
		const char *homeCString = getenv("HOME");
		NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
		if (home.length == 0) {
			home = NSHomeDirectory();
		}

		gHomePath = [home copy];
		gDocumentsPath = [[gHomePath stringByAppendingPathComponent:@"Documents"] copy];
		gAppGroupPath = [[gDocumentsPath stringByAppendingPathComponent:@"AppGroup"] copy];
		gHomeMobileConfigPath = [[gHomePath stringByAppendingPathComponent:@"mobileconfig"] copy];
		gDocumentsMobileConfigPath = [[gDocumentsPath stringByAppendingPathComponent:@"mobileconfig"] copy];
		gCanonicalMobileConfigPath = [[gAppGroupPath stringByAppendingPathComponent:@"mobileconfig"] copy];
	});
}

static NSString *documentsPath() {
	initializePathConstants();
	return gDocumentsPath;
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

NSURL *getAppGroupPathIfExists() {
	static NSURL *cachedAppGroupPath = nil;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		initializePathConstants();
		if (createDirectoryIfNotExists(gAppGroupPath)) {
			cachedAppGroupPath = [NSURL fileURLWithPath:gAppGroupPath isDirectory:YES];
		}
	});

	return cachedAppGroupPath;
}

static BOOL pathIsEqualToOrInsidePath(NSString *path, NSString *prefix) {
	if (path.length == 0 || prefix.length == 0) {
		return NO;
	}
	if ([path isEqualToString:prefix]) {
		return YES;
	}

	NSString *prefixWithSlash = [prefix stringByAppendingString:@"/"];
	return [path hasPrefix:prefixWithSlash];
}

NSString *canonicalizedSideloadPath(NSString *path) {
	if (path.length == 0 || gCanonicalizingSideloadPath) {
		return path;
	}

	gCanonicalizingSideloadPath = YES;
	initializePathConstants();

	NSString *result = path;
	NSArray<NSString *> *legacyPrefixes = @[gHomeMobileConfigPath, gDocumentsMobileConfigPath];
	for (NSString *legacyPrefix in legacyPrefixes) {
		if (!pathIsEqualToOrInsidePath(path, legacyPrefix)) {
			continue;
		}

		NSString *suffix = [path substringFromIndex:legacyPrefix.length];
		if ([suffix hasPrefix:@"/"]) {
			suffix = [suffix substringFromIndex:1];
		}

		result = suffix.length == 0
			? gCanonicalMobileConfigPath
			: [gCanonicalMobileConfigPath stringByAppendingPathComponent:suffix];
		break;
	}

	gCanonicalizingSideloadPath = NO;
	return result;
}

NSURL *canonicalizedSideloadURL(NSURL *url) {
	if (!url || !url.isFileURL) {
		return url;
	}

	NSString *canonicalPath = canonicalizedSideloadPath(url.path);
	if ([canonicalPath isEqualToString:url.path]) {
		return url;
	}
	return [NSURL fileURLWithPath:canonicalPath isDirectory:url.hasDirectoryPath];
}

static NSDate *modificationDateForPath(NSFileManager *fileManager, NSString *path) {
	NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
	return attributes[NSFileModificationDate];
}

static BOOL mergeLegacyItem(NSFileManager *fileManager, NSString *sourcePath, NSString *destinationPath) {
	BOOL sourceIsDirectory = NO;
	if (![fileManager fileExistsAtPath:sourcePath isDirectory:&sourceIsDirectory]) {
		return YES;
	}

	BOOL destinationIsDirectory = NO;
	BOOL destinationExists = [fileManager fileExistsAtPath:destinationPath isDirectory:&destinationIsDirectory];

	if (!destinationExists) {
		NSString *parent = [destinationPath stringByDeletingLastPathComponent];
		if (!createDirectoryIfNotExists(parent)) {
			return NO;
		}
		NSError *moveError = nil;
		return [fileManager moveItemAtPath:sourcePath toPath:destinationPath error:&moveError] && moveError == nil;
	}

	if (sourceIsDirectory && destinationIsDirectory) {
		NSError *contentsError = nil;
		NSArray<NSString *> *children = [fileManager contentsOfDirectoryAtPath:sourcePath error:&contentsError];
		if (!children || contentsError) {
			return NO;
		}

		BOOL merged = YES;
		for (NSString *child in children) {
			NSString *sourceChild = [sourcePath stringByAppendingPathComponent:child];
			NSString *destinationChild = [destinationPath stringByAppendingPathComponent:child];
			if (!mergeLegacyItem(fileManager, sourceChild, destinationChild)) {
				merged = NO;
			}
		}

		if (merged) {
			[fileManager removeItemAtPath:sourcePath error:nil];
		}
		return merged;
	}

	if (!sourceIsDirectory && !destinationIsDirectory) {
		NSDate *sourceDate = modificationDateForPath(fileManager, sourcePath);
		NSDate *destinationDate = modificationDateForPath(fileManager, destinationPath);
		BOOL sourceIsNewer = sourceDate && (!destinationDate || [sourceDate compare:destinationDate] == NSOrderedDescending);
		if (sourceIsNewer) {
			if (![fileManager removeItemAtPath:destinationPath error:nil]) {
				return NO;
			}
			NSError *moveError = nil;
			return [fileManager moveItemAtPath:sourcePath toPath:destinationPath error:&moveError] && moveError == nil;
		}

		[fileManager removeItemAtPath:sourcePath error:nil];
		return YES;
	}

	return NO;
}

void migrateLegacyMobileConfigIfNeeded() {
	initializePathConstants();
	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (!appGroupURL) {
		return;
	}

	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSArray<NSString *> *legacyPaths = @[gHomeMobileConfigPath, gDocumentsMobileConfigPath];

	for (NSString *legacyPath in legacyPaths) {
		if ([legacyPath isEqualToString:gCanonicalMobileConfigPath]) {
			continue;
		}
		mergeLegacyItem(fileManager, legacyPath, gCanonicalMobileConfigPath);
	}

	createDirectoryIfNotExists(gCanonicalMobileConfigPath);
}
