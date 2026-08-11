#import <Foundation/Foundation.h>
#import <dirent.h>
#import <fcntl.h>
#import <limits.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
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

static char gLegacyRootMobileConfigQCE[PATH_MAX];
static char gLegacyDocumentsMobileConfigQCE[PATH_MAX];
static char gCanonicalMobileConfigQCE[PATH_MAX];

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
static int (*orig_link_fn)(const char *, const char *);
static int (*orig_mkstemp_fn)(char *);
static int (*orig_statfs_fn)(const char *, struct statfs *);

static fs::file_status (*orig_fs_status_fn)(const fs::path &, std::error_code *);
static fs::file_status (*orig_fs_symlink_status_fn)(const fs::path &, std::error_code *);
static fs::path (*orig_fs_canonical_fn)(const fs::path &, std::error_code *);
static fs::path (*orig_fs_weakly_canonical_fn)(const fs::path &, std::error_code *);
static bool (*orig_fs_remove_fn)(const fs::path &, std::error_code *);
static uintmax_t (*orig_fs_remove_all_fn)(const fs::path &, std::error_code *);
static void (*orig_fs_rename_fn)(const fs::path &, const fs::path &, std::error_code *);
static bool (*orig_fs_create_directories_fn)(const fs::path &, std::error_code *);
static uintmax_t (*orig_fs_file_size_fn)(const fs::path &, std::error_code *);
static bool (*orig_fs_is_empty_fn)(const fs::path &, std::error_code *);
static fs::file_time_type (*orig_fs_last_write_time_fn)(const fs::path &, std::error_code *);
static fs::space_info (*orig_fs_space_fn)(const fs::path &, std::error_code *);
static void (*orig_fs_directory_iterator_ctor_fn)(fs::directory_iterator *, const fs::path &, std::error_code *, fs::directory_options);
static void (*orig_fs_recursive_directory_iterator_ctor_fn)(fs::recursive_directory_iterator *, const fs::path &, fs::directory_options, std::error_code *);

static BOOL pathMatchesPrefix(const char *path, const char *prefix) {
    if (!path || !prefix || !prefix[0]) return NO;
    size_t n = strlen(prefix);
    if (strncmp(path, prefix, n) != 0) return NO;
    char terminator = path[n];
    return terminator == '\0' || terminator == '/';
}

static const char *rewriteAgainstPair(const char *path,
                                      const char *legacyPrefix,
                                      const char *canonicalPrefix,
                                      char *buffer) {
    if (!pathMatchesPrefix(path, legacyPrefix)) return NULL;

    const char *suffix = path + strlen(legacyPrefix);
    int written = snprintf(buffer, PATH_MAX, "%s%s", canonicalPrefix, suffix);
    return (written < 0 || written >= PATH_MAX) ? NULL : buffer;
}

static const char *rewriteMobileConfigPath(const char *path, int slot) {
    if (!gPathPrefixesReady || !path) return path;

    static __thread char rewrittenPaths[2][PATH_MAX];
    char *buffer = rewrittenPaths[slot == 1 ? 1 : 0];
    const char *rewritten = NULL;

    rewritten = rewriteAgainstPair(path, gLegacyRootMobileConfig, gCanonicalMobileConfig, buffer);
    if (rewritten) return rewritten;

    rewritten = rewriteAgainstPair(path, gLegacyDocumentsMobileConfig, gCanonicalMobileConfig, buffer);
    if (rewritten) return rewritten;

    rewritten = rewriteAgainstPair(path, gLegacyRootMobileConfigQCE, gCanonicalMobileConfigQCE, buffer);
    if (rewritten) return rewritten;

    rewritten = rewriteAgainstPair(path, gLegacyDocumentsMobileConfigQCE, gCanonicalMobileConfigQCE, buffer);
    return rewritten ?: path;
}

static fs::path rewriteFSPath(const fs::path &path, int slot) {
    const std::string &native = path.native();
    const char *rewritten = rewriteMobileConfigPath(native.c_str(), slot);
    return rewritten == native.c_str() ? path : fs::path(rewritten);
}

static int zx_open(const char *path, int flags, ...) {
    const char *p = rewriteMobileConfigPath(path, 0);
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return orig_open_fn(p, flags, mode);
    }
    return orig_open_fn(p, flags);
}

static FILE *zx_fopen(const char *p, const char *m) {
    return orig_fopen_fn(rewriteMobileConfigPath(p, 0), m);
}

static int zx_stat(const char *p, struct stat *s) {
    return orig_stat_fn(rewriteMobileConfigPath(p, 0), s);
}

static int zx_lstat(const char *p, struct stat *s) {
    return orig_lstat_fn(rewriteMobileConfigPath(p, 0), s);
}

static int zx_access(const char *p, int m) {
    return orig_access_fn(rewriteMobileConfigPath(p, 0), m);
}

static int zx_mkdir(const char *p, mode_t m) {
    return orig_mkdir_fn(rewriteMobileConfigPath(p, 0), m);
}

static int zx_unlink(const char *p) {
    return orig_unlink_fn(rewriteMobileConfigPath(p, 0));
}

static int zx_rmdir(const char *p) {
    return orig_rmdir_fn(rewriteMobileConfigPath(p, 0));
}

static int zx_remove(const char *p) {
    return orig_remove_fn(rewriteMobileConfigPath(p, 0));
}

static int zx_rename(const char *a, const char *b) {
    return orig_rename_fn(rewriteMobileConfigPath(a, 0), rewriteMobileConfigPath(b, 1));
}

static DIR *zx_opendir(const char *p) {
    return orig_opendir_fn(rewriteMobileConfigPath(p, 0));
}

static int zx_link(const char *a, const char *b) {
    return orig_link_fn(rewriteMobileConfigPath(a, 0), rewriteMobileConfigPath(b, 1));
}

// mkstemp mutates the caller's template. Create the physical file using a
// canonical AppGroup template, then mirror only the generated basename back
// into the caller's original (virtual) path. This avoids requiring additional
// capacity in the caller's buffer when the canonical prefix is longer.
static int zx_mkstemp(char *pathTemplate) {
    if (!pathTemplate) return orig_mkstemp_fn(pathTemplate);

    const char *rewritten = rewriteMobileConfigPath(pathTemplate, 0);
    if (rewritten == pathTemplate) return orig_mkstemp_fn(pathTemplate);

    char canonicalTemplate[PATH_MAX];
    int written = snprintf(canonicalTemplate, sizeof(canonicalTemplate), "%s", rewritten);
    if (written < 0 || written >= (int)sizeof(canonicalTemplate)) {
        return orig_mkstemp_fn(pathTemplate);
    }

    int fd = orig_mkstemp_fn(canonicalTemplate);
    if (fd < 0) return fd;

    char *originalBase = strrchr(pathTemplate, '/');
    char *canonicalBase = strrchr(canonicalTemplate, '/');
    originalBase = originalBase ? originalBase + 1 : pathTemplate;
    canonicalBase = canonicalBase ? canonicalBase + 1 : canonicalTemplate;

    size_t originalBaseLength = strlen(originalBase);
    size_t canonicalBaseLength = strlen(canonicalBase);
    if (originalBaseLength == canonicalBaseLength) {
        memcpy(originalBase, canonicalBase, canonicalBaseLength + 1);
    }

    return fd;
}

static int zx_statfs(const char *p, struct statfs *s) {
    return orig_statfs_fn(rewriteMobileConfigPath(p, 0), s);
}

static fs::file_status zx_fs_status(const fs::path &p, std::error_code *e) {
    return orig_fs_status_fn(rewriteFSPath(p, 0), e);
}

static fs::file_status zx_fs_symlink_status(const fs::path &p, std::error_code *e) {
    return orig_fs_symlink_status_fn(rewriteFSPath(p, 0), e);
}

static fs::path zx_fs_canonical(const fs::path &p, std::error_code *e) {
    return orig_fs_canonical_fn(rewriteFSPath(p, 0), e);
}

static fs::path zx_fs_weakly_canonical(const fs::path &p, std::error_code *e) {
    return orig_fs_weakly_canonical_fn(rewriteFSPath(p, 0), e);
}

static bool zx_fs_remove(const fs::path &p, std::error_code *e) {
    return orig_fs_remove_fn(rewriteFSPath(p, 0), e);
}

static uintmax_t zx_fs_remove_all(const fs::path &p, std::error_code *e) {
    return orig_fs_remove_all_fn(rewriteFSPath(p, 0), e);
}

static void zx_fs_rename(const fs::path &a, const fs::path &b, std::error_code *e) {
    orig_fs_rename_fn(rewriteFSPath(a, 0), rewriteFSPath(b, 1), e);
}

static bool zx_fs_create_directories(const fs::path &p, std::error_code *e) {
    return orig_fs_create_directories_fn(rewriteFSPath(p, 0), e);
}

static uintmax_t zx_fs_file_size(const fs::path &p, std::error_code *e) {
    return orig_fs_file_size_fn(rewriteFSPath(p, 0), e);
}

static bool zx_fs_is_empty(const fs::path &p, std::error_code *e) {
    return orig_fs_is_empty_fn(rewriteFSPath(p, 0), e);
}

static fs::file_time_type zx_fs_last_write_time(const fs::path &p, std::error_code *e) {
    return orig_fs_last_write_time_fn(rewriteFSPath(p, 0), e);
}

static fs::space_info zx_fs_space(const fs::path &p, std::error_code *e) {
    return orig_fs_space_fn(rewriteFSPath(p, 0), e);
}

static void zx_fs_directory_iterator_ctor(fs::directory_iterator *self,
                                          const fs::path &p,
                                          std::error_code *e,
                                          fs::directory_options options) {
    orig_fs_directory_iterator_ctor_fn(self, rewriteFSPath(p, 0), e, options);
}

static void zx_fs_recursive_directory_iterator_ctor(fs::recursive_directory_iterator *self,
                                                    const fs::path &p,
                                                    fs::directory_options options,
                                                    std::error_code *e) {
    orig_fs_recursive_directory_iterator_ctor_fn(self, rewriteFSPath(p, 0), options, e);
}

void rebindPathFuncs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *homeCString = getenv("HOME");
        NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
        if (home.length == 0) home = NSHomeDirectory();

        NSString *documents = [home stringByAppendingPathComponent:@"Documents"];
        NSString *appGroup = [documents stringByAppendingPathComponent:@"AppGroup"];
        NSString *canonicalMobileConfig = [appGroup stringByAppendingPathComponent:@"mobileconfig"];
        NSString *canonicalMobileConfigQCE = [appGroup stringByAppendingPathComponent:@"mobileconfig_qce"];

        snprintf(gLegacyRootMobileConfig, PATH_MAX, "%s/mobileconfig", home.fileSystemRepresentation);
        snprintf(gLegacyDocumentsMobileConfig, PATH_MAX, "%s/mobileconfig", documents.fileSystemRepresentation);
        snprintf(gCanonicalMobileConfig, PATH_MAX, "%s", canonicalMobileConfig.fileSystemRepresentation);

        snprintf(gLegacyRootMobileConfigQCE, PATH_MAX, "%s/mobileconfig_qce", home.fileSystemRepresentation);
        snprintf(gLegacyDocumentsMobileConfigQCE, PATH_MAX, "%s/mobileconfig_qce", documents.fileSystemRepresentation);
        snprintf(gCanonicalMobileConfigQCE, PATH_MAX, "%s", canonicalMobileConfigQCE.fileSystemRepresentation);

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
            {"link", (void *)zx_link, (void **)&orig_link_fn},
            {"mkstemp", (void *)zx_mkstemp, (void **)&orig_mkstemp_fn},
            {"statfs", (void *)zx_statfs, (void **)&orig_statfs_fn},

            {"_ZNSt3__14__fs10filesystem8__statusERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_status, (void **)&orig_fs_status_fn},
            {"_ZNSt3__14__fs10filesystem16__symlink_statusERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_symlink_status, (void **)&orig_fs_symlink_status_fn},
            {"_ZNSt3__14__fs10filesystem11__canonicalERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_canonical, (void **)&orig_fs_canonical_fn},
            {"_ZNSt3__14__fs10filesystem18__weakly_canonicalERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_weakly_canonical, (void **)&orig_fs_weakly_canonical_fn},
            {"_ZNSt3__14__fs10filesystem8__removeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_remove, (void **)&orig_fs_remove_fn},
            {"_ZNSt3__14__fs10filesystem12__remove_allERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_remove_all, (void **)&orig_fs_remove_all_fn},
            {"_ZNSt3__14__fs10filesystem8__renameERKNS1_4pathES4_PNS_10error_codeE", (void *)zx_fs_rename, (void **)&orig_fs_rename_fn},
            {"_ZNSt3__14__fs10filesystem20__create_directoriesERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_create_directories, (void **)&orig_fs_create_directories_fn},
            {"_ZNSt3__14__fs10filesystem11__file_sizeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_file_size, (void **)&orig_fs_file_size_fn},
            {"_ZNSt3__14__fs10filesystem13__fs_is_emptyERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_is_empty, (void **)&orig_fs_is_empty_fn},
            {"_ZNSt3__14__fs10filesystem17__last_write_timeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_last_write_time, (void **)&orig_fs_last_write_time_fn},
            {"_ZNSt3__14__fs10filesystem7__spaceERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_space, (void **)&orig_fs_space_fn},
            {"_ZNSt3__14__fs10filesystem18directory_iteratorC1ERKNS1_4pathEPNS_10error_codeENS1_17directory_optionsE", (void *)zx_fs_directory_iterator_ctor, (void **)&orig_fs_directory_iterator_ctor_fn},
            {"_ZNSt3__14__fs10filesystem28recursive_directory_iteratorC1ERKNS1_4pathENS1_17directory_optionsEPNS_10error_codeE", (void *)zx_fs_recursive_directory_iterator_ctor, (void **)&orig_fs_recursive_directory_iterator_ctor_fn},
        };

        rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
    });
}
