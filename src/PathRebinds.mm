#import <Foundation/Foundation.h>
#import <dirent.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#include <filesystem>
#include <system_error>

#import "Header.h"
#import "../fishhook/fishhook.h"

namespace fs = std::filesystem;

static char gLegacyRootMobileConfig[PATH_MAX];
static char gLegacyDocumentsMobileConfig[PATH_MAX];
static char gCanonicalMobileConfig[PATH_MAX];
static BOOL gPathPrefixesReady = NO;

static int (*orig_open_fn)(const char *, int, ...);
static FILE *(*orig_fopen_fn)(const char *, const char *);
static int (*orig_stat_fn)(const char *, struct stat *);
static int (*orig_lstat_fn)(const char *, struct stat *);
static int (*orig_access_fn)(const char *, int);
static int (*orig_mkdir_fn)(const char *, mode_t);
static int (*orig_unlink_fn)(const char *);
static int (*orig_rmdir_fn)(const char *);
static int (*orig_remove_fn)(const char *);
static int (*orig_rename_fn)(const char *, const char *);
static DIR *(*orig_opendir_fn)(const char *);

// Forum's MobileConfig storage backend calls these libc++ filesystem entrypoints
// directly. Rebinding only open/mkdir/NSFileManager is not sufficient because
// libc++ can perform the underlying filesystem operation inside the shared cache.
static fs::file_status (*orig_fs_status_fn)(const fs::path &, std::error_code *);
static bool (*orig_fs_remove_fn)(const fs::path &, std::error_code *);
static void (*orig_fs_rename_fn)(const fs::path &, const fs::path &, std::error_code *);
static bool (*orig_fs_create_directories_fn)(const fs::path &, std::error_code *);
static uintmax_t (*orig_fs_file_size_fn)(const fs::path &, std::error_code *);

static BOOL pathMatchesPrefix(const char *path, const char *prefix) {
    if (!path || !prefix || !prefix[0]) {
        return NO;
    }

    size_t prefixLength = strlen(prefix);
    if (strncmp(path, prefix, prefixLength) != 0) {
        return NO;
    }

    char terminator = path[prefixLength];
    return terminator == '\0' || terminator == '/';
}

static const char *rewriteMobileConfigPath(const char *path, int slot) {
    if (!gPathPrefixesReady || !path) {
        return path;
    }

    const char *matchedPrefix = NULL;
    if (pathMatchesPrefix(path, gLegacyRootMobileConfig)) {
        matchedPrefix = gLegacyRootMobileConfig;
    } else if (pathMatchesPrefix(path, gLegacyDocumentsMobileConfig)) {
        matchedPrefix = gLegacyDocumentsMobileConfig;
    } else {
        return path;
    }

    static __thread char rewrittenPaths[2][PATH_MAX];
    char *buffer = rewrittenPaths[(slot == 1) ? 1 : 0];
    const char *suffix = path + strlen(matchedPrefix);
    int written = snprintf(buffer, PATH_MAX, "%s%s", gCanonicalMobileConfig, suffix);
    if (written < 0 || written >= PATH_MAX) {
        return path;
    }

    return buffer;
}

static fs::path rewriteMobileConfigFilesystemPath(const fs::path &path, int slot) {
    const std::string &native = path.native();
    const char *rewritten = rewriteMobileConfigPath(native.c_str(), slot);
    if (rewritten == native.c_str()) {
        return path;
    }
    return fs::path(rewritten);
}

static int zx_open(const char *path, int oflag, ...) {
    const char *rewritten = rewriteMobileConfigPath(path, 0);
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode_t mode = (mode_t)va_arg(args, int);
        va_end(args);
        return orig_open_fn(rewritten, oflag, mode);
    }
    return orig_open_fn(rewritten, oflag);
}

static FILE *zx_fopen(const char *path, const char *mode) {
    return orig_fopen_fn(rewriteMobileConfigPath(path, 0), mode);
}

static int zx_stat(const char *path, struct stat *buf) {
    return orig_stat_fn(rewriteMobileConfigPath(path, 0), buf);
}

static int zx_lstat(const char *path, struct stat *buf) {
    return orig_lstat_fn(rewriteMobileConfigPath(path, 0), buf);
}

static int zx_access(const char *path, int mode) {
    return orig_access_fn(rewriteMobileConfigPath(path, 0), mode);
}

static int zx_mkdir(const char *path, mode_t mode) {
    return orig_mkdir_fn(rewriteMobileConfigPath(path, 0), mode);
}

static int zx_unlink(const char *path) {
    return orig_unlink_fn(rewriteMobileConfigPath(path, 0));
}

static int zx_rmdir(const char *path) {
    return orig_rmdir_fn(rewriteMobileConfigPath(path, 0));
}

static int zx_remove(const char *path) {
    return orig_remove_fn(rewriteMobileConfigPath(path, 0));
}

static int zx_rename(const char *oldPath, const char *newPath) {
    const char *rewrittenOldPath = rewriteMobileConfigPath(oldPath, 0);
    const char *rewrittenNewPath = rewriteMobileConfigPath(newPath, 1);
    return orig_rename_fn(rewrittenOldPath, rewrittenNewPath);
}

static DIR *zx_opendir(const char *path) {
    return orig_opendir_fn(rewriteMobileConfigPath(path, 0));
}

static fs::file_status zx_fs_status(const fs::path &path, std::error_code *error) {
    fs::path rewritten = rewriteMobileConfigFilesystemPath(path, 0);
    return orig_fs_status_fn(rewritten, error);
}

static bool zx_fs_remove(const fs::path &path, std::error_code *error) {
    fs::path rewritten = rewriteMobileConfigFilesystemPath(path, 0);
    return orig_fs_remove_fn(rewritten, error);
}

static void zx_fs_rename(const fs::path &oldPath, const fs::path &newPath, std::error_code *error) {
    fs::path rewrittenOld = rewriteMobileConfigFilesystemPath(oldPath, 0);
    fs::path rewrittenNew = rewriteMobileConfigFilesystemPath(newPath, 1);
    orig_fs_rename_fn(rewrittenOld, rewrittenNew, error);
}

static bool zx_fs_create_directories(const fs::path &path, std::error_code *error) {
    fs::path rewritten = rewriteMobileConfigFilesystemPath(path, 0);
    return orig_fs_create_directories_fn(rewritten, error);
}

static uintmax_t zx_fs_file_size(const fs::path &path, std::error_code *error) {
    fs::path rewritten = rewriteMobileConfigFilesystemPath(path, 0);
    return orig_fs_file_size_fn(rewritten, error);
}

void rebindPathFuncs() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *homeCString = getenv("HOME");
        NSString *homePath = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
        if (homePath.length == 0) {
            homePath = NSHomeDirectory();
        }
        NSString *documentsPath = [homePath stringByAppendingPathComponent:@"Documents"];
        NSString *canonicalPath = [[documentsPath stringByAppendingPathComponent:@"AppGroup"] stringByAppendingPathComponent:@"mobileconfig"];

        snprintf(gLegacyRootMobileConfig, PATH_MAX, "%s/mobileconfig", homePath.fileSystemRepresentation);
        snprintf(gLegacyDocumentsMobileConfig, PATH_MAX, "%s/mobileconfig", documentsPath.fileSystemRepresentation);
        snprintf(gCanonicalMobileConfig, PATH_MAX, "%s", canonicalPath.fileSystemRepresentation);
        gPathPrefixesReady = YES;

        struct rebinding bindings[] = {
            {"open", (void *)zx_open, (void **)&orig_open_fn},
            {"fopen", (void *)zx_fopen, (void **)&orig_fopen_fn},
            {"stat", (void *)zx_stat, (void **)&orig_stat_fn},
            {"lstat", (void *)zx_lstat, (void **)&orig_lstat_fn},
            {"access", (void *)zx_access, (void **)&orig_access_fn},
            {"mkdir", (void *)zx_mkdir, (void **)&orig_mkdir_fn},
            {"unlink", (void *)zx_unlink, (void **)&orig_unlink_fn},
            {"rmdir", (void *)zx_rmdir, (void **)&orig_rmdir_fn},
            {"remove", (void *)zx_remove, (void **)&orig_remove_fn},
            {"rename", (void *)zx_rename, (void **)&orig_rename_fn},
            {"opendir", (void *)zx_opendir, (void **)&orig_opendir_fn},

            // Mach-O symbol names have one additional leading underscore;
            // fishhook compares after stripping that prefix, so use _ZN... here.
            {"_ZNSt3__14__fs10filesystem8__statusERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_status, (void **)&orig_fs_status_fn},
            {"_ZNSt3__14__fs10filesystem8__removeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_remove, (void **)&orig_fs_remove_fn},
            {"_ZNSt3__14__fs10filesystem8__renameERKNS1_4pathES4_PNS_10error_codeE", (void *)zx_fs_rename, (void **)&orig_fs_rename_fn},
            {"_ZNSt3__14__fs10filesystem20__create_directoriesERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_create_directories, (void **)&orig_fs_create_directories_fn},
            {"_ZNSt3__14__fs10filesystem11__file_sizeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_file_size, (void **)&orig_fs_file_size_fn},
        };

        rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
    });
}
