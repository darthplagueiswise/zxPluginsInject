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

static fs::file_status (*orig_fs_status_fn)(const fs::path &, std::error_code *);
static bool (*orig_fs_remove_fn)(const fs::path &, std::error_code *);
static void (*orig_fs_rename_fn)(const fs::path &, const fs::path &, std::error_code *);
static bool (*orig_fs_create_directories_fn)(const fs::path &, std::error_code *);
static uintmax_t (*orig_fs_file_size_fn)(const fs::path &, std::error_code *);

static BOOL pathMatchesPrefix(const char *path, const char *prefix) {
	if (!path || !prefix || !prefix[0]) return NO;
	size_t n = strlen(prefix);
	if (strncmp(path, prefix, n) != 0) return NO;
	char terminator = path[n];
	return terminator == '\0' || terminator == '/';
}

static const char *rewriteMobileConfigPath(const char *path, int slot) {
	if (!gPathPrefixesReady || !path) return path;
	const char *prefix = NULL;
	if (pathMatchesPrefix(path, gLegacyRootMobileConfig)) prefix = gLegacyRootMobileConfig;
	else if (pathMatchesPrefix(path, gLegacyDocumentsMobileConfig)) prefix = gLegacyDocumentsMobileConfig;
	else return path;
	static __thread char rewrittenPaths[2][PATH_MAX];
	char *buffer = rewrittenPaths[slot == 1 ? 1 : 0];
	const char *suffix = path + strlen(prefix);
	int written = snprintf(buffer, PATH_MAX, "%s%s", gCanonicalMobileConfig, suffix);
	return (written < 0 || written >= PATH_MAX) ? path : buffer;
}

static fs::path rewriteFSPath(const fs::path &path, int slot) {
	const std::string &native = path.native();
	const char *rewritten = rewriteMobileConfigPath(native.c_str(), slot);
	return rewritten == native.c_str() ? path : fs::path(rewritten);
}

static int zx_open(const char *path, int flags, ...) {
	const char *p = rewriteMobileConfigPath(path, 0);
	if (flags & O_CREAT) {
		va_list ap; va_start(ap, flags); mode_t mode = (mode_t)va_arg(ap, int); va_end(ap);
		return orig_open_fn(p, flags, mode);
	}
	return orig_open_fn(p, flags);
}
static FILE *zx_fopen(const char *p, const char *m) { return orig_fopen_fn(rewriteMobileConfigPath(p,0), m); }
static int zx_stat(const char *p, struct stat *s) { return orig_stat_fn(rewriteMobileConfigPath(p,0), s); }
static int zx_lstat(const char *p, struct stat *s) { return orig_lstat_fn(rewriteMobileConfigPath(p,0), s); }
static int zx_access(const char *p, int m) { return orig_access_fn(rewriteMobileConfigPath(p,0), m); }
static int zx_mkdir(const char *p, mode_t m) { return orig_mkdir_fn(rewriteMobileConfigPath(p,0), m); }
static int zx_unlink(const char *p) { return orig_unlink_fn(rewriteMobileConfigPath(p,0)); }
static int zx_rmdir(const char *p) { return orig_rmdir_fn(rewriteMobileConfigPath(p,0)); }
static int zx_remove(const char *p) { return orig_remove_fn(rewriteMobileConfigPath(p,0)); }
static int zx_rename(const char *a, const char *b) { return orig_rename_fn(rewriteMobileConfigPath(a,0), rewriteMobileConfigPath(b,1)); }
static DIR *zx_opendir(const char *p) { return orig_opendir_fn(rewriteMobileConfigPath(p,0)); }

static fs::file_status zx_fs_status(const fs::path &p, std::error_code *e) { return orig_fs_status_fn(rewriteFSPath(p,0), e); }
static bool zx_fs_remove(const fs::path &p, std::error_code *e) { return orig_fs_remove_fn(rewriteFSPath(p,0), e); }
static void zx_fs_rename(const fs::path &a, const fs::path &b, std::error_code *e) { orig_fs_rename_fn(rewriteFSPath(a,0), rewriteFSPath(b,1), e); }
static bool zx_fs_create_directories(const fs::path &p, std::error_code *e) { return orig_fs_create_directories_fn(rewriteFSPath(p,0), e); }
static uintmax_t zx_fs_file_size(const fs::path &p, std::error_code *e) { return orig_fs_file_size_fn(rewriteFSPath(p,0), e); }

void rebindPathFuncs(void) {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		const char *homeCString = getenv("HOME");
		NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
		if (home.length == 0) home = NSHomeDirectory();
		NSString *documents = [home stringByAppendingPathComponent:@"Documents"];
		NSString *canonical = [[documents stringByAppendingPathComponent:@"AppGroup"] stringByAppendingPathComponent:@"mobileconfig"];
		snprintf(gLegacyRootMobileConfig, PATH_MAX, "%s/mobileconfig", home.fileSystemRepresentation);
		snprintf(gLegacyDocumentsMobileConfig, PATH_MAX, "%s/mobileconfig", documents.fileSystemRepresentation);
		snprintf(gCanonicalMobileConfig, PATH_MAX, "%s", canonical.fileSystemRepresentation);
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
			{"_ZNSt3__14__fs10filesystem8__statusERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_status, (void **)&orig_fs_status_fn},
			{"_ZNSt3__14__fs10filesystem8__removeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_remove, (void **)&orig_fs_remove_fn},
			{"_ZNSt3__14__fs10filesystem8__renameERKNS1_4pathES4_PNS_10error_codeE", (void *)zx_fs_rename, (void **)&orig_fs_rename_fn},
			{"_ZNSt3__14__fs10filesystem20__create_directoriesERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_create_directories, (void **)&orig_fs_create_directories_fn},
			{"_ZNSt3__14__fs10filesystem11__file_sizeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_file_size, (void **)&orig_fs_file_size_fn},
		};
		rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
	});
}
