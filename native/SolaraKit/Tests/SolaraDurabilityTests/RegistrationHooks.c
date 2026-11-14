#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static sqlite3_vfs proxy;
static sqlite3_vfs *original;

static int replaced_fstat(int fd, struct stat *info) {
  return fstat(fd, info);
}

static int failed_install(sqlite3_vfs *vfs, const char *name, sqlite3_syscall_ptr function) {
  (void)vfs;
  (void)name;
  (void)function;
  return SQLITE_NOTFOUND;
}

static int ignored_install(sqlite3_vfs *vfs, const char *name, sqlite3_syscall_ptr function) {
  (void)vfs;
  (void)name;
  (void)function;
  return SQLITE_OK;
}

static sqlite3_syscall_ptr replaced_get(sqlite3_vfs *vfs, const char *name) {
  (void)vfs;
  return strcmp(name, "fstat") == 0 ? (sqlite3_syscall_ptr)replaced_fstat : original->xGetSystemCall(original, name);
}

static sqlite3_vfs *intercept_find(const char *name) {
  sqlite3_vfs *found = sqlite3_vfs_find(name);
  const char *mode = getenv("SD_TEST_REGISTRATION_FAILURE");
  if (!found || !name || strcmp(name, "unix") != 0 || !mode) return found;
  original = found;
  proxy = *found;
  if (strcmp(mode, "version") == 0) proxy.iVersion = 2;
  if (strcmp(mode, "install") == 0) proxy.xSetSystemCall = failed_install;
  if (strcmp(mode, "ignored") == 0) proxy.xSetSystemCall = ignored_install;
  if (strcmp(mode, "collision") == 0) proxy.xGetSystemCall = replaced_get;
  return &proxy;
}

static int intercept_register(sqlite3_vfs *vfs, int make_default) {
  const char *mode = getenv("SD_TEST_REGISTRATION_FAILURE");
  if (mode && strcmp(mode, "register") == 0 && strcmp(vfs->zName, "solara-durable") == 0) return SQLITE_ERROR;
  return sqlite3_vfs_register(vfs, make_default);
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement; const void *original; } interposers[] = {
  {(const void *)intercept_find, (const void *)sqlite3_vfs_find},
  {(const void *)intercept_register, (const void *)sqlite3_vfs_register}
};
