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

// One rule per (legacy root x relocated leaf). "mobileconfig_qce" needs its own
// rule: pathMatchesPrefix requires '/' or NUL after the prefix, so a rule for
// "mobileconfig" can never match ".../mobileconfig_qce".
#define ZX_MAX_RULES 8
typedef struct {
	char legacy[PATH_MAX];
	char canonical[PATH_MAX];
} zx_rule_t;

static zx_rule_t gRules[ZX_MAX_RULES];
static int gRuleCount = 0;
static BOOL gPathPrefixesReady = NO;

// Slots must outnumber the paths any single hooked call rewrites at once.
// rename/renameat rewrite two.
#define ZX_SLOT_COUNT 4

static int (*orig_open_fn)(const char *, int, ...);
static int (*orig_openat_fn)(int, const char *, int, ...);
static int (*orig_open_dprotected_np_fn)(const char *, int, int, int, ...);
static FILE *(*orig_fopen_fn)(const char *, const char *);
static int (*orig_stat_fn)(const char *, struct stat *);
static int (*orig_lstat_fn)(const char *, struct stat *);
static int (*orig_access_fn)(const char *, int);
static int (*orig_mkdir_fn)(const char *, mode_t);
static int (*orig_mkdirat_fn)(int, const char *, mode_t);
static int (*orig_unlink_fn)(const char *);
static int (*orig_unlinkat_fn)(int, const char *, int);
static int (*orig_rmdir_fn)(const char *);
static int (*orig_remove_fn)(const char *);
static int (*orig_rename_fn)(const char *, const char *);
static int (*orig_renameat_fn)(int, const char *, int, const char *);
static DIR *(*orig_opendir_fn)(const char *);

static fs::file_status (*orig_fs_status_fn)(const fs::path &, std::error_code *);
static fs::file_status (*orig_fs_symlink_status_fn)(const fs::path &, std::error_code *);
static bool (*orig_fs_remove_fn)(const fs::path &, std::error_code *);
static uintmax_t (*orig_fs_remove_all_fn)(const fs::path &, std::error_code *);
static void (*orig_fs_rename_fn)(const fs::path &, const fs::path &, std::error_code *);
static bool (*orig_fs_create_directories_fn)(const fs::path &, std::error_code *);
static uintmax_t (*orig_fs_file_size_fn)(const fs::path &, std::error_code *);
static fs::path (*orig_fs_canonical_fn)(const fs::path &, std::error_code *);
static fs::path (*orig_fs_weakly_canonical_fn)(const fs::path &, std::error_code *);
static fs::file_time_type (*orig_fs_last_write_time_fn)(const fs::path &, std::error_code *);
static bool (*orig_fs_is_empty_fn)(const fs::path &, std::error_code *);
static void (*orig_dir_iterator_ctor_fn)(void *, const fs::path &, std::error_code *, fs::directory_options);
static void (*orig_rec_dir_iterator_ctor_fn)(void *, const fs::path &, fs::directory_options, std::error_code *);

// /var is a symlink to /private/var. Paths that have been through realpath(),
// std::filesystem::canonical() or -[NSURL fileSystemRepresentation] arrive in
// the /private form, while the prefixes built from getenv("HOME") are in the
// /var form, so a raw strncmp misses them and the write lands outside the
// container. Only a prefix is removed, so no copy is needed.
static const char *zxStandardizePath(const char *path) {
	if (!path) return path;
	if (strncmp(path, "/private/var/", 13) == 0 || strncmp(path, "/private/tmp/", 13) == 0) {
		return path + 8;
	}
	return path;
}

static BOOL pathMatchesPrefix(const char *path, const char *prefix) {
	if (!path || !prefix || !prefix[0]) return NO;
	size_t n = strlen(prefix);
	if (strncmp(path, prefix, n) != 0) return NO;
	char terminator = path[n];
	return terminator == '\0' || terminator == '/';
}

static const char *rewriteMobileConfigPath(const char *path, int slot) {
	if (!gPathPrefixesReady || !path) return path;
	const char *standardized = zxStandardizePath(path);
	for (int i = 0; i < gRuleCount; i++) {
		if (!pathMatchesPrefix(standardized, gRules[i].legacy)) continue;
		static __thread char rewrittenPaths[ZX_SLOT_COUNT][PATH_MAX];
		char *buffer = rewrittenPaths[(slot >= 0 && slot < ZX_SLOT_COUNT) ? slot : 0];
		const char *suffix = standardized + strlen(gRules[i].legacy);
		int written = snprintf(buffer, PATH_MAX, "%s%s", gRules[i].canonical, suffix);
		return (written < 0 || written >= PATH_MAX) ? path : buffer;
	}
	return path;
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

// Relative paths are resolved against the directory fd, so leave them alone.
static int zx_openat(int fd, const char *path, int flags, ...) {
	const char *p = (path && path[0] == '/') ? rewriteMobileConfigPath(path, 0) : path;
	if (flags & O_CREAT) {
		va_list ap; va_start(ap, flags); mode_t mode = (mode_t)va_arg(ap, int); va_end(ap);
		return orig_openat_fn(fd, p, flags, mode);
	}
	return orig_openat_fn(fd, p, flags);
}

static int zx_open_dprotected_np(const char *path, int flags, int protClass, int dpflags, ...) {
	const char *p = rewriteMobileConfigPath(path, 0);
	if (flags & O_CREAT) {
		va_list ap; va_start(ap, dpflags); mode_t mode = (mode_t)va_arg(ap, int); va_end(ap);
		return orig_open_dprotected_np_fn(p, flags, protClass, dpflags, mode);
	}
	return orig_open_dprotected_np_fn(p, flags, protClass, dpflags);
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

static int zx_mkdirat(int fd, const char *p, mode_t m) {
	return orig_mkdirat_fn(fd, (p && p[0] == '/') ? rewriteMobileConfigPath(p,0) : p, m);
}
static int zx_unlinkat(int fd, const char *p, int flag) {
	return orig_unlinkat_fn(fd, (p && p[0] == '/') ? rewriteMobileConfigPath(p,0) : p, flag);
}
static int zx_renameat(int fromfd, const char *from, int tofd, const char *to) {
	const char *f = (from && from[0] == '/') ? rewriteMobileConfigPath(from,0) : from;
	const char *t = (to && to[0] == '/') ? rewriteMobileConfigPath(to,1) : to;
	return orig_renameat_fn(fromfd, f, tofd, t);
}

static fs::file_status zx_fs_status(const fs::path &p, std::error_code *e) { return orig_fs_status_fn(rewriteFSPath(p,0), e); }
static fs::file_status zx_fs_symlink_status(const fs::path &p, std::error_code *e) { return orig_fs_symlink_status_fn(rewriteFSPath(p,0), e); }
static bool zx_fs_remove(const fs::path &p, std::error_code *e) { return orig_fs_remove_fn(rewriteFSPath(p,0), e); }
static uintmax_t zx_fs_remove_all(const fs::path &p, std::error_code *e) { return orig_fs_remove_all_fn(rewriteFSPath(p,0), e); }
static void zx_fs_rename(const fs::path &a, const fs::path &b, std::error_code *e) { orig_fs_rename_fn(rewriteFSPath(a,0), rewriteFSPath(b,1), e); }
static bool zx_fs_create_directories(const fs::path &p, std::error_code *e) { return orig_fs_create_directories_fn(rewriteFSPath(p,0), e); }
static uintmax_t zx_fs_file_size(const fs::path &p, std::error_code *e) { return orig_fs_file_size_fn(rewriteFSPath(p,0), e); }
static bool zx_fs_is_empty(const fs::path &p, std::error_code *e) { return orig_fs_is_empty_fn(rewriteFSPath(p,0), e); }
static fs::file_time_type zx_fs_last_write_time(const fs::path &p, std::error_code *e) { return orig_fs_last_write_time_fn(rewriteFSPath(p,0), e); }

// canonical()/weakly_canonical() are the reason the /private form shows up at
// all: they run the path through realpath(). Rewriting the input keeps the
// result inside the container, and zxStandardizePath handles the /private form
// the callee hands back.
static fs::path zx_fs_canonical(const fs::path &p, std::error_code *e) { return orig_fs_canonical_fn(rewriteFSPath(p,0), e); }
static fs::path zx_fs_weakly_canonical(const fs::path &p, std::error_code *e) { return orig_fs_weakly_canonical_fn(rewriteFSPath(p,0), e); }

// libc++ resolves opendir() internally, from inside the shared cache, where
// fishhook cannot reach it - so the directory iterators need their own rebind
// or a scan of the legacy directory silently returns nothing.
static void zx_dir_iterator_ctor(void *self, const fs::path &p, std::error_code *e, fs::directory_options opts) {
	orig_dir_iterator_ctor_fn(self, rewriteFSPath(p,0), e, opts);
}
static void zx_rec_dir_iterator_ctor(void *self, const fs::path &p, fs::directory_options opts, std::error_code *e) {
	orig_rec_dir_iterator_ctor_fn(self, rewriteFSPath(p,0), opts, e);
}

static void zxAddRule(NSString *legacyPrefix, NSString *canonicalPrefix) {
	if (gRuleCount >= ZX_MAX_RULES) return;
	snprintf(gRules[gRuleCount].legacy, PATH_MAX, "%s", legacyPrefix.fileSystemRepresentation);
	snprintf(gRules[gRuleCount].canonical, PATH_MAX, "%s", canonicalPrefix.fileSystemRepresentation);
	gRuleCount++;
}

void rebindPathFuncs(void) {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		const char *homeCString = getenv("HOME");
		NSString *home = homeCString ? [NSString stringWithUTF8String:homeCString] : nil;
		if (home.length == 0) home = NSHomeDirectory();
		home = standardizedSideloadPath(home);
		NSString *documents = [home stringByAppendingPathComponent:@"Documents"];
		NSString *appGroup = [documents stringByAppendingPathComponent:@"AppGroup"];

		for (NSString *leaf in @[@"mobileconfig", @"mobileconfig_qce"]) {
			NSString *canonical = [appGroup stringByAppendingPathComponent:leaf];
			zxAddRule([home stringByAppendingPathComponent:leaf], canonical);
			zxAddRule([documents stringByAppendingPathComponent:leaf], canonical);
		}
		gPathPrefixesReady = YES;

		struct rebinding bindings[] = {
			{"open", (void *)zx_open, (void **)&orig_open_fn},
			{"openat", (void *)zx_openat, (void **)&orig_openat_fn},
			{"open_dprotected_np", (void *)zx_open_dprotected_np, (void **)&orig_open_dprotected_np_fn},
			{"fopen", (void *)zx_fopen, (void **)&orig_fopen_fn},
			{"stat", (void *)zx_stat, (void **)&orig_stat_fn},
			{"lstat", (void *)zx_lstat, (void **)&orig_lstat_fn},
			{"access", (void *)zx_access, (void **)&orig_access_fn},
			{"mkdir", (void *)zx_mkdir, (void **)&orig_mkdir_fn},
			{"mkdirat", (void *)zx_mkdirat, (void **)&orig_mkdirat_fn},
			{"unlink", (void *)zx_unlink, (void **)&orig_unlink_fn},
			{"unlinkat", (void *)zx_unlinkat, (void **)&orig_unlinkat_fn},
			{"rmdir", (void *)zx_rmdir, (void **)&orig_rmdir_fn},
			{"remove", (void *)zx_remove, (void **)&orig_remove_fn},
			{"rename", (void *)zx_rename, (void **)&orig_rename_fn},
			{"renameat", (void *)zx_renameat, (void **)&orig_renameat_fn},
			{"opendir", (void *)zx_opendir, (void **)&orig_opendir_fn},
			{"_ZNSt3__14__fs10filesystem8__statusERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_status, (void **)&orig_fs_status_fn},
			{"_ZNSt3__14__fs10filesystem16__symlink_statusERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_symlink_status, (void **)&orig_fs_symlink_status_fn},
			{"_ZNSt3__14__fs10filesystem8__removeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_remove, (void **)&orig_fs_remove_fn},
			{"_ZNSt3__14__fs10filesystem12__remove_allERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_remove_all, (void **)&orig_fs_remove_all_fn},
			{"_ZNSt3__14__fs10filesystem8__renameERKNS1_4pathES4_PNS_10error_codeE", (void *)zx_fs_rename, (void **)&orig_fs_rename_fn},
			{"_ZNSt3__14__fs10filesystem20__create_directoriesERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_create_directories, (void **)&orig_fs_create_directories_fn},
			{"_ZNSt3__14__fs10filesystem11__file_sizeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_file_size, (void **)&orig_fs_file_size_fn},
			{"_ZNSt3__14__fs10filesystem13__fs_is_emptyERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_is_empty, (void **)&orig_fs_is_empty_fn},
			{"_ZNSt3__14__fs10filesystem11__canonicalERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_canonical, (void **)&orig_fs_canonical_fn},
			{"_ZNSt3__14__fs10filesystem18__weakly_canonicalERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_weakly_canonical, (void **)&orig_fs_weakly_canonical_fn},
			{"_ZNSt3__14__fs10filesystem17__last_write_timeERKNS1_4pathEPNS_10error_codeE", (void *)zx_fs_last_write_time, (void **)&orig_fs_last_write_time_fn},
			{"_ZNSt3__14__fs10filesystem18directory_iteratorC1ERKNS1_4pathEPNS_10error_codeENS1_17directory_optionsE", (void *)zx_dir_iterator_ctor, (void **)&orig_dir_iterator_ctor_fn},
			{"_ZNSt3__14__fs10filesystem28recursive_directory_iteratorC1ERKNS1_4pathENS1_17directory_optionsEPNS_10error_codeE", (void *)zx_rec_dir_iterator_ctor, (void **)&orig_rec_dir_iterator_ctor_fn},
		};
		rebind_symbols(bindings, sizeof(bindings) / sizeof(bindings[0]));
	});
}
