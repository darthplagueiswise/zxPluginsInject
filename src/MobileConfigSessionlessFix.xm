#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Forum (com.facebook.agora) registers an XPlugins provider for key
// 0x495bbe12 that returns nil. Its sessionless bootstrap consequently passes
// NSDocumentDirectory to FBMobileConfigInitParams. Account/admin managers use
// the AppGroup path, which is why only sessionless.data is recreated outside
// Documents/AppGroup. Fix the semantic input before MobileConfig derives the
// mobileconfig and mobileconfig_qce directories from it.

@interface FBMobileConfigInitParams : NSObject
- (int)unitType;
- (void)setContainerPath:(NSString *)containerPath;
@end

static BOOL zxIsForumHost(void) {
	return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.facebook.agora"];
}

static NSString *zxComparablePath(NSString *path) {
	NSString *standardized = path.stringByStandardizingPath;
	if ([standardized hasPrefix:@"/private/var/"] ||
		[standardized hasPrefix:@"/private/tmp/"]) {
		return [standardized substringFromIndex:8];
	}
	return standardized;
}

static NSString *zxDocumentsPath(void) {
	NSString *path = NSSearchPathForDirectoriesInDomains(
		NSDocumentDirectory,
		NSUserDomainMask,
		YES
	).lastObject;
	return zxComparablePath(path);
}

static NSString *zxPathFromMETAAppGroup(void) {
	Class appGroupClass = objc_getClass("METAAppGroup");
	SEL groupSelector = NSSelectorFromString(@"appGroupForGroupName:");
	SEL containerSelector = NSSelectorFromString(@"containerURL");
	if (!appGroupClass || ![appGroupClass respondsToSelector:groupSelector]) {
		return nil;
	}

	id group = ((id (*)(id, SEL, id))objc_msgSend)(
		(id)appGroupClass,
		groupSelector,
		@"app"
	);
	if (!group || ![group respondsToSelector:containerSelector]) {
		return nil;
	}

	id value = ((id (*)(id, SEL))objc_msgSend)(group, containerSelector);
	if ([value isKindOfClass:NSURL.class]) {
		return zxComparablePath(((NSURL *)value).path);
	}
	if ([value isKindOfClass:NSString.class]) {
		return zxComparablePath((NSString *)value);
	}
	return nil;
}

static NSString *zxCanonicalForumAppGroupRoot(void) {
	NSString *root = zxPathFromMETAAppGroup();
	if (!root.length) {
		// Do not depend on the older path-rebinding workaround here. This is the
		// exact jailed AppGroup location used by the sideload shim.
		root = [zxDocumentsPath() stringByAppendingPathComponent:@"AppGroup"];
	}

	NSError *error = nil;
	[NSFileManager.defaultManager createDirectoryAtPath:root
						 withIntermediateDirectories:YES
									  attributes:nil
										   error:&error];
	if (error) {
		NSLog(@"[zx][forum-mobileconfig] cannot create AppGroup root %@: %@", root, error);
		return nil;
	}
	return zxComparablePath(root);
}

static BOOL zxJSONContainsNameEntries(NSData *data) {
	if (!data.length) return NO;

	NSError *error = nil;
	id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
	if (error || ![value isKindOfClass:NSArray.class]) return NO;

	for (id entry in (NSArray *)value) {
		if ([entry isKindOfClass:NSString.class] && ((NSString *)entry).length > 0) {
			return YES;
		}
	}
	return NO;
}

static NSString *zxBundledForumParamsNamesPath(void) {
	NSBundle *bundle = NSBundle.mainBundle;
	NSString *path = [bundle pathForResource:@"params_names_v4_u0"
									 ofType:@"txt"
								inDirectory:@"params_maps"];
	if (!path.length) {
		path = [bundle pathForResource:@"params_names_v4_u0"
								 ofType:@"txt"
							inDirectory:@"mobileconfig_res"];
	}
	return path;
}

// Advanced Settings reads mg from
// <container>/mobileconfig/id_name_mapping.json. Forum bundles the same JSON
// representation in params_maps/params_names_v4_u0.txt, while both captured
// runtime cache files contain [] and the global file is absent. Seed only a
// missing/invalid global map; a later successful refresh can replace it.
static void zxSeedForumIdNameMappingIfNeeded(NSString *containerRoot) {
	if (!containerRoot.length) return;

	static NSObject *lock;
	static BOOL completed;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		lock = [NSObject new];
	});

	@synchronized (lock) {
		if (completed) return;

		NSString *mobileConfigDirectory =
			[containerRoot stringByAppendingPathComponent:@"mobileconfig"];
		NSString *destination =
			[mobileConfigDirectory stringByAppendingPathComponent:@"id_name_mapping.json"];
		NSData *current = [NSData dataWithContentsOfFile:destination];
		if (zxJSONContainsNameEntries(current)) {
			completed = YES;
			return;
		}

		NSString *source = zxBundledForumParamsNamesPath();
		NSData *seed = source.length ? [NSData dataWithContentsOfFile:source] : nil;
		if (!zxJSONContainsNameEntries(seed)) {
			NSLog(@"[zx][forum-mobileconfig] bundled params_names_v4_u0 is absent or invalid");
			return;
		}

		NSError *error = nil;
		[NSFileManager.defaultManager createDirectoryAtPath:mobileConfigDirectory
							 withIntermediateDirectories:YES
										  attributes:nil
											   error:&error];
		if (!error) {
			[seed writeToFile:destination options:NSDataWritingAtomic error:&error];
		}
		if (error) {
			NSLog(@"[zx][forum-mobileconfig] cannot seed %@: %@", destination, error);
			return;
		}

		completed = YES;
		NSLog(@"[zx][forum-mobileconfig] seeded id/name mapping %@ -> %@", source, destination);
	}
}

%hook FBMobileConfigInitParams

- (void)setContainerPath:(NSString *)containerPath {
	if (!zxIsForumHost() || [self unitType] != 1) {
		%orig(containerPath);
		return;
	}

	NSString *effectivePath = zxComparablePath(containerPath);
	NSString *documents = zxDocumentsPath();
	if (!effectivePath.length || [effectivePath isEqualToString:documents]) {
		NSString *corrected = zxCanonicalForumAppGroupRoot();
		if (corrected.length) {
			NSLog(@"[zx][forum-mobileconfig] sessionless container %@ -> %@",
			effectivePath ?: @"(nil)", corrected);
			effectivePath = corrected;
		}
	}

	zxSeedForumIdNameMappingIfNeeded(effectivePath);
	%orig(effectivePath);
}

%end
