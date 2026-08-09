#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Header.h"

%hook CKContainer
- (id)_setupWithContainerID:(id)a options:(id)b {
	return nil;
}

- (id)_initWithContainerIdentifier:(id)a {
	return nil;
}
%end

%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)entitlements {
	NSMutableDictionary *mutableEntitlements = [entitlements mutableCopy];
	[mutableEntitlements removeObjectForKey:@"com.apple.developer.icloud-container-environment"];
	[mutableEntitlements removeObjectForKey:@"com.apple.developer.icloud-services"];
	NSDictionary *cleanEntitlements = [mutableEntitlements copy];
	return %orig(cleanEntitlements);
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	if (groupIdentifier != nil) {
		NSURL *fallback = getAppGroupPathIfExists();
		if (fallback) {
			return fallback;
		}
	}
	return %orig(groupIdentifier);
}

- (BOOL)fileExistsAtPath:(NSString *)path {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath);
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath, isDirectory);
}

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath, createIntermediates, attributes, error);
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attributes {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath, data, attributes);
}

- (NSData *)contentsAtPath:(NSString *)path {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath);
}

- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath, error);
}

- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath, error);
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
	NSString *mappedPath = canonicalizedSideloadPath(path);
	return %orig(mappedPath, error);
}

- (BOOL)copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
	NSString *mappedSource = canonicalizedSideloadPath(srcPath);
	NSString *mappedDestination = canonicalizedSideloadPath(dstPath);
	return %orig(mappedSource, mappedDestination, error);
}

- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
	NSString *mappedSource = canonicalizedSideloadPath(srcPath);
	NSString *mappedDestination = canonicalizedSideloadPath(dstPath);
	return %orig(mappedSource, mappedDestination, error);
}

- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error {
	NSURL *mappedURL = canonicalizedSideloadURL(url);
	return %orig(mappedURL, createIntermediates, attributes, error);
}

- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error {
	NSURL *mappedURL = canonicalizedSideloadURL(url);
	return %orig(mappedURL, error);
}

- (BOOL)copyItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
	NSURL *mappedSource = canonicalizedSideloadURL(srcURL);
	NSURL *mappedDestination = canonicalizedSideloadURL(dstURL);
	return %orig(mappedSource, mappedDestination, error);
}

- (BOOL)moveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
	NSURL *mappedSource = canonicalizedSideloadURL(srcURL);
	NSURL *mappedDestination = canonicalizedSideloadURL(dstURL);
	return %orig(mappedSource, mappedDestination, error);
}

- (NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask error:(NSError **)error {
	NSURL *mappedURL = canonicalizedSideloadURL(url);
	return %orig(mappedURL, keys, mask, error);
}
%end

static const void *kZXSuiteNameKey = &kZXSuiteNameKey;
static const void *kZXMirrorDefaultsKey = &kZXMirrorDefaultsKey;
static __thread BOOL gZXDefaultsFanout = NO;

static BOOL zxIsGroupSuite(NSString *suiteName) {
	return [suiteName isKindOfClass:[NSString class]] && [suiteName hasPrefix:@"group"];
}

static NSUserDefaults *zxMirrorDefaults(NSUserDefaults *defaults) {
	if (!defaults || gZXDefaultsFanout) {
		return nil;
	}

	NSString *suiteName = objc_getAssociatedObject(defaults, kZXSuiteNameKey);
	if (!zxIsGroupSuite(suiteName)) {
		return nil;
	}

	NSUserDefaults *mirror = objc_getAssociatedObject(defaults, kZXMirrorDefaultsKey);
	if (mirror) {
		return mirror;
	}

	NSURL *container = getAppGroupPathIfExists();
	if (!container) {
		return nil;
	}

	gZXDefaultsFanout = YES;
	SEL privateInit = NSSelectorFromString(@"_initWithSuiteName:container:");
	id allocated = [NSUserDefaults alloc];
	if ([allocated respondsToSelector:privateInit]) {
		mirror = ((id (*)(id, SEL, NSString *, NSURL *))objc_msgSend)(allocated, privateInit, suiteName, container);
	}
	gZXDefaultsFanout = NO;

	if (mirror && mirror != defaults) {
		objc_setAssociatedObject(defaults, kZXMirrorDefaultsKey, mirror, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		return mirror;
	}
	return nil;
}

%hook NSUserDefaults
- (id)initWithSuiteName:(NSString *)suiteName {
	id result = %orig(suiteName);
	if (result && zxIsGroupSuite(suiteName)) {
		objc_setAssociatedObject(result, kZXSuiteNameKey, suiteName, OBJC_ASSOCIATION_COPY_NONATOMIC);
	}
	return result;
}

- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (gZXDefaultsFanout || !zxIsGroupSuite(suiteName)) {
		return %orig(suiteName, container);
	}

	NSURL *mapped = getAppGroupPathIfExists();
	NSURL *effectiveContainer = mapped ? mapped : container;
	id result = %orig(suiteName, effectiveContainer);
	if (result) {
		objc_setAssociatedObject(result, kZXSuiteNameKey, suiteName, OBJC_ASSOCIATION_COPY_NONATOMIC);
	}
	return result;
}

- (id)objectForKey:(NSString *)key {
	id value = %orig(key);
	if (value || gZXDefaultsFanout) {
		return value;
	}
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) {
		return value;
	}
	gZXDefaultsFanout = YES;
	id mirrored = [mirror objectForKey:key];
	gZXDefaultsFanout = NO;
	return mirrored;
}

- (void)setObject:(id)value forKey:(NSString *)key {
	%orig(value, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror setObject:value forKey:key];
	gZXDefaultsFanout = NO;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
	%orig(value, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror setBool:value forKey:key];
	gZXDefaultsFanout = NO;
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
	%orig(value, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror setInteger:value forKey:key];
	gZXDefaultsFanout = NO;
}

- (void)setDouble:(double)value forKey:(NSString *)key {
	%orig(value, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror setDouble:value forKey:key];
	gZXDefaultsFanout = NO;
}

- (void)setFloat:(float)value forKey:(NSString *)key {
	%orig(value, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror setFloat:value forKey:key];
	gZXDefaultsFanout = NO;
}

- (void)setURL:(NSURL *)url forKey:(NSString *)key {
	%orig(url, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror setURL:url forKey:key];
	gZXDefaultsFanout = NO;
}

- (void)setValue:(id)value forKey:(NSString *)key {
	%orig(value, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror setValue:value forKey:key];
	gZXDefaultsFanout = NO;
}

- (void)removeObjectForKey:(NSString *)key {
	%orig(key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return;
	gZXDefaultsFanout = YES;
	[mirror removeObjectForKey:key];
	gZXDefaultsFanout = NO;
}

- (BOOL)synchronize {
	BOOL originalOK = %orig;
	if (gZXDefaultsFanout) {
		return originalOK;
	}
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) {
		return originalOK;
	}
	gZXDefaultsFanout = YES;
	BOOL mirrorOK = [mirror synchronize];
	gZXDefaultsFanout = NO;
	return originalOK && mirrorOK;
}
%end

%ctor {
	migrateLegacyMobileConfigIfNeeded();
	rebindPathFuncs();
	%init;
}
