#import <Foundation/Foundation.h>

// Meta builds do not use one stable bundle subdirectory for MobileConfig
// seed resources. Facebook currently ships them under mobileconfig_res while
// Forum ships the same resource family under params_maps. Keep the app's
// native lookup first and alias only the missing mobileconfig_res directory.
%hook NSBundle

- (NSString *)pathForResource:(NSString *)name
                       ofType:(NSString *)extension
                  inDirectory:(NSString *)subpath {
    NSString *path = %orig(name, extension, subpath);
    if (path.length > 0 || ![subpath isEqualToString:@"mobileconfig_res"]) {
        return path;
    }

    NSString *fallback = %orig(name, extension, @"params_maps");
    return fallback.length > 0 ? fallback : path;
}

- (NSURL *)URLForResource:(NSString *)name
            withExtension:(NSString *)extension
             subdirectory:(NSString *)subpath {
    NSURL *url = %orig(name, extension, subpath);
    if (url || ![subpath isEqualToString:@"mobileconfig_res"]) {
        return url;
    }

    return %orig(name, extension, @"params_maps");
}

%end
