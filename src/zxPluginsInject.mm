#import "Header.h"

NSString *accessGroupId;
NSString *bundleId;

static void setRequiredIDs(void) {
	NSDictionary *query = @{
		(__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
		(__bridge NSString *)kSecAttrAccount: @"bundleSeedID",
		(__bridge NSString *)kSecAttrService: @"",
		(__bridge id)kSecReturnAttributes: (id)kCFBooleanTrue
	};

	CFDictionaryRef result = nil;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
	if (status == errSecItemNotFound) {
		NSMutableDictionary *addQuery = [query mutableCopy];
		addQuery[(__bridge NSString *)kSecAttrAccessible] = (__bridge NSString *)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
		status = SecItemAdd((__bridge CFDictionaryRef)addQuery, (CFTypeRef *)&result);
	} else if (status == errSecSuccess) {
		NSDictionary *accessibleUpdate = @{
			(__bridge NSString *)kSecAttrAccessible: (__bridge NSString *)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		};
		SecItemUpdate((__bridge CFDictionaryRef)@{
			(__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
			(__bridge NSString *)kSecAttrAccount: @"bundleSeedID",
			(__bridge NSString *)kSecAttrService: @""
		}, (__bridge CFDictionaryRef)accessibleUpdate);
	}
	if (status != errSecSuccess || !result) return;

	bundleId = [[NSBundle mainBundle] bundleIdentifier];
	accessGroupId = [(__bridge NSDictionary *)result objectForKey:(__bridge NSString *)kSecAttrAccessGroup];
	CFRelease(result);
}

__attribute__((constructor)) static void init(void) {
	setRequiredIDs();
	rebindSecFuncs();
}
