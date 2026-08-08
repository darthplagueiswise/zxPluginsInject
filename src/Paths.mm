#import <objc/runtime.h>

#import "Header.h"

static NSString *documentsPath() {
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *path = [paths lastObject];
	if (path.length == 0) {
		path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
	}
	return [path stringByStandardizingPath];
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
		NSString *path = [documentsPath() stringByAppendingPathComponent:@"AppGroup"];
		if (createDirectoryIfNotExists(path)) {
			cachedAppGroupPath = [NSURL fileURLWithPath:path isDirectory:YES];
		}
	});

	return cachedAppGroupPath;
}

static BOOL pathIsEqualToOrInsidePath(NSString *path, NSString *prefix) {
	if (path.length == 0 || prefix.length == 0) {
		return NO;
	}

	NSString *standardPath = [path stringByStandardizingPath];
	NSString *standardPrefix = [prefix stringByStandardizingPath];
	if ([standardPath isEqualToString:standardPrefix]) {
		return YES;
	}

	NSString *prefixWithSlash = [standardPrefix stringByAppendingString:@"/"];
	return [standardPath hasPrefix:prefixWithSlash];
}

NSString *canonicalizedSideloadPath(NSString *path) {
	if (path.length == 0) {
		return path;
	}

	NSString *standardPath = [path stringByStandardizingPath];
	NSString *homeMobileConfig = [[NSHomeDirectory() stringByStandardizingPath] stringByAppendingPathComponent:@"mobileconfig"];
	NSString *documentsMobileConfig = [documentsPath() stringByAppendingPathComponent:@"mobileconfig"];
	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (!appGroupURL) {
		return standardPath;
	}

	NSString *targetMobileConfig = [appGroupURL.path stringByAppendingPathComponent:@"mobileconfig"];
	NSArray<NSString *> *legacyPrefixes = @[homeMobileConfig, documentsMobileConfig];
	for (NSString *legacyPrefix in legacyPrefixes) {
		if (!pathIsEqualToOrInsidePath(standardPath, legacyPrefix)) {
			continue;
		}

		NSString *suffix = [standardPath substringFromIndex:legacyPrefix.length];
		if ([suffix hasPrefix:@"/"]) {
			suffix = [suffix substringFromIndex:1];
		}

		if (suffix.length == 0) {
			return targetMobileConfig;
		}
		return [targetMobileConfig stringByAppendingPathComponent:suffix];
	}

	return standardPath;
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
	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (!appGroupURL) {
		return;
	}

	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSString *targetPath = [appGroupURL.path stringByAppendingPathComponent:@"mobileconfig"];
	NSString *homePath = [NSHomeDirectory() stringByStandardizingPath];
	NSString *documents = documentsPath();
	NSArray<NSString *> *legacyPaths = @[
		[homePath stringByAppendingPathComponent:@"mobileconfig"],
		[documents stringByAppendingPathComponent:@"mobileconfig"]
	];

	for (NSString *legacyPath in legacyPaths) {
		if ([legacyPath isEqualToString:targetPath]) {
			continue;
		}
		mergeLegacyItem(fileManager, legacyPath, targetPath);
	}

	createDirectoryIfNotExists(targetPath);
}
