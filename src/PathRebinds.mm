#import <Foundation/Foundation.h>
#import <dirent.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "Header.h"
#import "../fishhook/fishhook.h"

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

void rebindPathFuncs() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *homePath = [NSHomeDirectory() stringByStandardizingPath];
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
        };

        rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
    });
}
