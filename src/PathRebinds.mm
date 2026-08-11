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

// O redirecionamento aqui e REDE DE SEGURANCA, nao o caminho principal.
// Quando containerURLForSecurityApplicationGroupIdentifier: devolve uma URL boa,
// o proprio app monta <AppGroup>/mobileconfig/ e nenhuma regra abaixo chega a
// casar. Por isso a lista de rebinds cobre so leitura/escrita de path, e
// deliberadamente NAO cobre:
//
//   __remove_all  - e recursivo. Um remove_all num diretorio legado (que antes
//                   estava vazio ou nem existia) passa a apontar para o store
//                   real dentro do AppGroup e apaga os dados de verdade.
//   directory_iterator / recursive_directory_iterator ctors
//                 - no Apple ARM64 o clang usa a variante ARM do Itanium, onde
//                   construtor devolve `this` em x0. Um replacement declarado
//                   void deixa x0 indefinido.
//   __canonical / __weakly_canonical
//                 - mudam o valor que o app CALCULA, nao so onde ele le. Esse
//                   valor pode acabar persistido e comparado depois.
//
// A correcao de verdade e a normalizacao do /private logo abaixo.

// Uma regra por (raiz legada x leaf). "mobileconfig_qce" precisa de regra
// propria: pathMatchesPrefix exige '/' ou NUL depois do prefixo, entao uma
// regra de "mobileconfig" nunca casa com "mobileconfig_qce". O sufixo _qce vem
// do init-param bufferPathPostfix do proprio MobileConfig, ou seja, os dois
// stores saem do mesmo base.
#define ZX_MAX_RULES 8
typedef struct {
	char legacy[PATH_MAX];
	char canonical[PATH_MAX];
} zx_rule_t;

static zx_rule_t gRules[ZX_MAX_RULES];
static int gRuleCount = 0;
static BOOL gPathPrefixesReady = NO;

// rename reescreve dois paths na mesma chamada.
#define ZX_SLOT_COUNT 2

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

// /var e um symlink para /private/var. getenv("HOME") e NSHomeDirectory()
// devolvem a forma /var, mas qualquer path que passou por realpath(),
// std::filesystem::canonical() ou -[NSURL fileSystemRepresentation] volta como
// /private/var, e o strncmp contra o prefixo falha - a escrita vaza para fora
// do container. Como so um prefixo e removido, nao precisa de copia.
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
