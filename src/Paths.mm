#import <stdlib.h>
#import "Header.h"

static NSString *gHomePath = nil;
static NSString *gDocumentsPath = nil;
static NSString *gAppGroupPath = nil;

static NSString *gHomeMobileConfigPath = nil;
static NSString *gDocumentsMobileConfigPath = nil;
static NSString *gCanonicalMobileConfigPath = nil;

static NSString *gHomeMobileConfigQCEPath = nil;
static NSString *gDocumentsMobileConfigQCEPath = nil;
static NSString *gCanonicalMobileConfigQCEPath = nil;

static dispatch_once_t gPathConstantsOnce;
static __thread BOOL gCanonicalizingSideloadPath = NO;

static void initializePathConstants(void) {
    dispatch_once(&gPathConstantsOnce, ^{
        const char *homeCString = getenv("HOME");
        NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
        if (home.length == 0) home = NSHomeDirectory();

        gHomePath = [home copy];
        gDocumentsPath = [[gHomePath stringByAppendingPathComponent:@"Documents"] copy];
        gAppGroupPath = [[gDocumentsPath stringByAppendingPathComponent:@"AppGroup"] copy];

        gHomeMobileConfigPath = [[gHomePath stringByAppendingPathComponent:@"mobileconfig"] copy];
        gDocumentsMobileConfigPath = [[gDocumentsPath stringByAppendingPathComponent:@"mobileconfig"] copy];
        gCanonicalMobileConfigPath = [[gAppGroupPath stringByAppendingPathComponent:@"mobileconfig"] copy];

        gHomeMobileConfigQCEPath = [[gHomePath stringByAppendingPathComponent:@"mobileconfig_qce"] copy];
        gDocumentsMobileConfigQCEPath = [[gDocumentsPath stringByAppendingPathComponent:@"mobileconfig_qce"] copy];
        gCanonicalMobileConfigQCEPath = [[gAppGroupPath stringByAppendingPathComponent:@"mobileconfig_qce"] copy];
    });
}

BOOL createDirectoryIfNotExists(NSString *path) {
    if (path.length == 0) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDirectory]) return isDirectory;

    NSError *error = nil;
    BOOL created = [fm createDirectoryAtPath:path
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:&error];
    return created && error == nil;
}

NSURL *getAppGroupPathIfExists(void) {
    static NSURL *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        initializePathConstants();
        if (createDirectoryIfNotExists(gAppGroupPath)) {
            cached = [NSURL fileURLWithPath:gAppGroupPath isDirectory:YES];
        }
    });
    return cached;
}

static BOOL pathIsEqualToOrInsidePath(NSString *path, NSString *prefix) {
    if (path.length == 0 || prefix.length == 0) return NO;
    if ([path isEqualToString:prefix]) return YES;
    return [path hasPrefix:[prefix stringByAppendingString:@"/"]];
}

static NSString *pathByRebindingLegacyRoot(NSString *path,
                                           NSString *legacyPrefix,
                                           NSString *canonicalPrefix) {
    if (!pathIsEqualToOrInsidePath(path, legacyPrefix)) return nil;

    NSString *suffix = [path substringFromIndex:legacyPrefix.length];
    if ([suffix hasPrefix:@"/"]) suffix = [suffix substringFromIndex:1];
    return suffix.length == 0
        ? canonicalPrefix
        : [canonicalPrefix stringByAppendingPathComponent:suffix];
}

NSString *canonicalizedSideloadPath(NSString *path) {
    if (path.length == 0 || gCanonicalizingSideloadPath) return path;

    gCanonicalizingSideloadPath = YES;
    initializePathConstants();

    NSString *result = path;
    NSArray<NSArray<NSString *> *> *mappings = @[
        @[gHomeMobileConfigPath, gCanonicalMobileConfigPath],
        @[gDocumentsMobileConfigPath, gCanonicalMobileConfigPath],
        @[gHomeMobileConfigQCEPath, gCanonicalMobileConfigQCEPath],
        @[gDocumentsMobileConfigQCEPath, gCanonicalMobileConfigQCEPath],
    ];

    for (NSArray<NSString *> *mapping in mappings) {
        NSString *mapped = pathByRebindingLegacyRoot(path, mapping[0], mapping[1]);
        if (mapped) {
            result = mapped;
            break;
        }
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
            NSString *sourceChild = [sourcePath stringByAppendingPathComponent:child];
            NSString *destinationChild = [destinationPath stringByAppendingPathComponent:child];
            if (!mergeLegacyItem(fm, sourceChild, destinationChild)) merged = NO;
        }
        if (merged) [fm removeItemAtPath:sourcePath error:nil];
        return merged;
    }

    if (!sourceIsDirectory && !destinationIsDirectory) {
        NSDate *sourceDate = modificationDateForPath(fm, sourcePath);
        NSDate *destinationDate = modificationDateForPath(fm, destinationPath);
        BOOL sourceIsNewer = sourceDate &&
            (!destinationDate || [sourceDate compare:destinationDate] == NSOrderedDescending);

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

static void migrateLegacyFamily(NSFileManager *fm,
                                NSString *homePath,
                                NSString *documentsPath,
                                NSString *canonicalPath) {
    mergeLegacyItem(fm, homePath, canonicalPath);
    mergeLegacyItem(fm, documentsPath, canonicalPath);
    createDirectoryIfNotExists(canonicalPath);
}

void migrateLegacyMobileConfigIfNeeded(void) {
    initializePathConstants();
    if (!getAppGroupPathIfExists()) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    migrateLegacyFamily(fm,
                        gHomeMobileConfigPath,
                        gDocumentsMobileConfigPath,
                        gCanonicalMobileConfigPath);
    migrateLegacyFamily(fm,
                        gHomeMobileConfigQCEPath,
                        gDocumentsMobileConfigQCEPath,
                        gCanonicalMobileConfigQCEPath);
}
