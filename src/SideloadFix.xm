#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Header.h"

%hook CKContainer
- (id)_setupWithContainerID:(id)a options:(id)b { return nil; }
- (id)_initWithContainerIdentifier:(id)a { return nil; }
%end

%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)entitlements {
	NSMutableDictionary *mutableEntitlements = [entitlements mutableCopy];
	[mutableEntitlements removeObjectForKey:@"com.apple.developer.icloud-container-environment"];
	[mutableEntitlements removeObjectForKey:@"com.apple.developer.icloud-services"];
	return %orig([mutableEntitlements copy]);
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	// Exact behavior of the supplied SideloadKeychainFix: every non-nil App Group
	// resolves to one deterministic sandbox-backed AppGroup directory.
	if (groupIdentifier != nil) {
		NSURL *fallback = getAppGroupPathIfExists();
		if (fallback) return fallback;
	}
	return %orig(groupIdentifier);
}

- (BOOL)fileExistsAtPath:(NSString *)path { return %orig(canonicalizedSideloadPath(path)); }
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory { return %orig(canonicalizedSideloadPath(path), isDirectory); }
- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error { return %orig(canonicalizedSideloadPath(path), createIntermediates, attributes, error); }
- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary *)attributes { return %orig(canonicalizedSideloadPath(path), data, attributes); }
- (NSData *)contentsAtPath:(NSString *)path { return %orig(canonicalizedSideloadPath(path)); }
- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error { return %orig(canonicalizedSideloadPath(path), error); }
- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error { return %orig(canonicalizedSideloadPath(path), error); }
- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error { return %orig(canonicalizedSideloadPath(path), error); }
- (BOOL)copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error { return %orig(canonicalizedSideloadPath(srcPath), canonicalizedSideloadPath(dstPath), error); }
- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error { return %orig(canonicalizedSideloadPath(srcPath), canonicalizedSideloadPath(dstPath), error); }
- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary *)attributes error:(NSError **)error { return %orig(canonicalizedSideloadURL(url), createIntermediates, attributes, error); }
- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error { return %orig(canonicalizedSideloadURL(url), error); }
- (BOOL)copyItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error { return %orig(canonicalizedSideloadURL(srcURL), canonicalizedSideloadURL(dstURL), error); }
- (BOOL)moveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error { return %orig(canonicalizedSideloadURL(srcURL), canonicalizedSideloadURL(dstURL), error); }
- (NSArray<NSURL *> *)contentsOfDirectoryAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask error:(NSError **)error { return %orig(canonicalizedSideloadURL(url), keys, mask, error); }
%end

static const void *kZXSuiteNameKey = &kZXSuiteNameKey;
static const void *kZXMirrorDefaultsKey = &kZXMirrorDefaultsKey;
static __thread BOOL gZXDefaultsFanout = NO;

static BOOL zxIsGroupSuite(NSString *suiteName) {
	return [suiteName isKindOfClass:[NSString class]] && [suiteName hasPrefix:@"group"];
}

static NSUserDefaults *zxMirrorDefaults(NSUserDefaults *defaults) {
	if (!defaults || gZXDefaultsFanout) return nil;
	NSString *suiteName = objc_getAssociatedObject(defaults, kZXSuiteNameKey);
	if (!zxIsGroupSuite(suiteName)) return nil;
	NSUserDefaults *mirror = objc_getAssociatedObject(defaults, kZXMirrorDefaultsKey);
	if (mirror) return mirror;
	NSURL *container = getAppGroupPathIfExists();
	if (!container) return nil;
	gZXDefaultsFanout = YES;
	SEL privateInit = NSSelectorFromString(@"_initWithSuiteName:container:");
	if ([[NSUserDefaults alloc] respondsToSelector:privateInit]) {
		id allocated = [NSUserDefaults alloc];
		mirror = ((id (*)(id, SEL, NSString *, NSURL *))objc_msgSend)(allocated, privateInit, suiteName, container);
	}
	gZXDefaultsFanout = NO;
	if (mirror && mirror != defaults) objc_setAssociatedObject(defaults, kZXMirrorDefaultsKey, mirror, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return mirror == defaults ? nil : mirror;
}

%hook NSUserDefaults
- (id)initWithSuiteName:(NSString *)suiteName {
	id result = %orig(suiteName);
	if (result && zxIsGroupSuite(suiteName)) objc_setAssociatedObject(result, kZXSuiteNameKey, suiteName, OBJC_ASSOCIATION_COPY_NONATOMIC);
	return result;
}

- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	if (gZXDefaultsFanout || !zxIsGroupSuite(suiteName)) return %orig(suiteName, container);
	NSURL *mapped = getAppGroupPathIfExists();
	id result = %orig(suiteName, mapped ?: container);
	if (result) objc_setAssociatedObject(result, kZXSuiteNameKey, suiteName, OBJC_ASSOCIATION_COPY_NONATOMIC);
	return result;
}

- (id)objectForKey:(NSString *)key {
	id value = %orig(key);
	if (value || gZXDefaultsFanout) return value;
	NSUserDefaults *mirror = zxMirrorDefaults(self);
	if (!mirror) return value;
	gZXDefaultsFanout = YES;
	id mirrored = [mirror objectForKey:key];
	gZXDefaultsFanout = NO;
	return mirrored;
}

- (void)setObject:(id)value forKey:(NSString *)key {
	%orig(value, key);
	if (gZXDefaultsFanout) return;
	NSUserDefaults *mirror = zxMirrorDefaults(self); if (!mirror) return;
	gZXDefaultsFanout = YES; [mirror setObject:value forKey:key]; gZXDefaultsFanout = NO;
}
- (void)setBool:(BOOL)value forKey:(NSString *)key { %orig(value,key); if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;[m setBool:value forKey:key];gZXDefaultsFanout=NO;} } }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { %orig(value,key); if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;[m setInteger:value forKey:key];gZXDefaultsFanout=NO;} } }
- (void)setDouble:(double)value forKey:(NSString *)key { %orig(value,key); if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;[m setDouble:value forKey:key];gZXDefaultsFanout=NO;} } }
- (void)setFloat:(float)value forKey:(NSString *)key { %orig(value,key); if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;[m setFloat:value forKey:key];gZXDefaultsFanout=NO;} } }
- (void)setURL:(NSURL *)url forKey:(NSString *)key { %orig(url,key); if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;[m setURL:url forKey:key];gZXDefaultsFanout=NO;} } }
- (void)setValue:(id)value forKey:(NSString *)key { %orig(value,key); if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;[m setValue:value forKey:key];gZXDefaultsFanout=NO;} } }
- (void)removeObjectForKey:(NSString *)key { %orig(key); if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;[m removeObjectForKey:key];gZXDefaultsFanout=NO;} } }
- (BOOL)synchronize { BOOL ok=%orig; if (!gZXDefaultsFanout) { NSUserDefaults *m=zxMirrorDefaults(self); if(m){gZXDefaultsFanout=YES;BOOL mOK=[m synchronize];gZXDefaultsFanout=NO;ok=ok&&mOK;} } return ok; }
%end

%ctor {
	migrateLegacyMobileConfigIfNeeded();
	rebindPathFuncs();
	%init;
}
