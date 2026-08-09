#import "Header.h"

NSString *accessGroupId;
NSString *bundleId;

static NSString *ensureKeychainMarker(NSString *account, BOOL normalizeAccessibility) {
	if (account.length == 0) {
		return nil;
	}

	NSDictionary *baseQuery = @{
		(__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
		(__bridge NSString *)kSecAttrAccount: account,
		(__bridge NSString *)kSecAttrService: @""
	};
	NSMutableDictionary *readQuery = [baseQuery mutableCopy];
	readQuery[(__bridge NSString *)kSecReturnAttributes] = (id)kCFBooleanTrue;

	CFDictionaryRef result = nil;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)readQuery, (CFTypeRef *)&result);
	if (status == errSecItemNotFound) {
		NSMutableDictionary *addQuery = [readQuery mutableCopy];
		if (normalizeAccessibility) {
			addQuery[(__bridge NSString *)kSecAttrAccessible] = (__bridge NSString *)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
		}
		status = SecItemAdd((__bridge CFDictionaryRef)addQuery, (CFTypeRef *)&result);
	} else if (status == errSecSuccess && normalizeAccessibility) {
		NSDictionary *accessibleUpdate = @{
			(__bridge NSString *)kSecAttrAccessible: (__bridge NSString *)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		};
		SecItemUpdate((__bridge CFDictionaryRef)baseQuery, (__bridge CFDictionaryRef)accessibleUpdate);
	}

	if (status != errSecSuccess || !result) {
		if (result) {
			CFRelease(result);
		}
		return nil;
	}

	NSString *group = [(__bridge NSDictionary *)result objectForKey:(__bridge NSString *)kSecAttrAccessGroup];
	NSString *copiedGroup = [group copy];
	CFRelease(result);
	return copiedGroup;
}

static void setRequiredIDs(void) {
	// SideloadKeychainFix marker.
	NSString *bundleSeedGroup = ensureKeychainMarker(@"bundleSeedID", NO);

	// zxPluginsInject / magic marker. magic additionally normalizes this item's
	// accessibility to AfterFirstUnlockThisDeviceOnly.
	NSString *genericGroup = ensureKeychainMarker(@"zxPluginsInjectGenericEntry", YES);

	bundleId = [[NSBundle mainBundle] bundleIdentifier];
	accessGroupId = bundleSeedGroup ?: genericGroup;
}

__attribute__((constructor)) static void init(void) {
	setRequiredIDs();
	rebindSecFuncs();
}
