#import "Header.h"

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

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (appGroupURL) {
		return appGroupURL;
	}
	return %orig(groupIdentifier);
}

- (BOOL)fileExistsAtPath:(NSString *)path {
	return %orig(canonicalizedSideloadPath(path));
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
	return %orig(canonicalizedSideloadPath(path), isDirectory);
}

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error {
	return %orig(canonicalizedSideloadPath(path), createIntermediates, attributes, error);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attributes {
	return %orig(canonicalizedSideloadPath(path), data, attributes);
}

- (NSData *)contentsAtPath:(NSString *)path {
	return %orig(canonicalizedSideloadPath(path));
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
	return %orig(canonicalizedSideloadPath(path), error);
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
	return %orig(canonicalizedSideloadPath(path), error);
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
	return %orig(canonicalizedSideloadPath(path), error);
}

- (BOOL)copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
	return %orig(canonicalizedSideloadPath(srcPath), canonicalizedSideloadPath(dstPath), error);
}

- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
	return %orig(canonicalizedSideloadPath(srcPath), canonicalizedSideloadPath(dstPath), error);
}

- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error {
	return %orig(canonicalizedSideloadURL(url), createIntermediates, attributes, error);
}

- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error {
	return %orig(canonicalizedSideloadURL(url), error);
}

- (BOOL)copyItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
	return %orig(canonicalizedSideloadURL(srcURL), canonicalizedSideloadURL(dstURL), error);
}

- (BOOL)moveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
	return %orig(canonicalizedSideloadURL(srcURL), canonicalizedSideloadURL(dstURL), error);
}

- (NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask error:(NSError **)error {
	return %orig(canonicalizedSideloadURL(url), keys, mask, error);
}
%end

%hook NSUserDefaults
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (![suiteName hasPrefix:@"group"]) {
		return %orig(suiteName, container);
	}

	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (appGroupURL) {
		return %orig(suiteName, appGroupURL);
	}
	return %orig(suiteName, container);
}
%end

%ctor {
	migrateLegacyMobileConfigIfNeeded();
	rebindPathFuncs();
	%init;
}
