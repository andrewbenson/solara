#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <objc/runtime.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fault_mode;
static int fault_hits;

static IMP original_resource_values;
static id fault_objc_resource_values(id object, SEL selector, id keys, id *error);

void solara_discovery_fault(int mode) {
  if (mode >= 6 && !original_resource_values) {
    Method method = class_getInstanceMethod(objc_getClass("NSURL"), sel_registerName("resourceValuesForKeys:error:"));
    original_resource_values = method_setImplementation(method, (IMP)fault_objc_resource_values);
  }
  fault_mode = mode;
  fault_hits = 0;
}

int solara_discovery_fault_hits(void) {
  return fault_hits;
}

static int target_fd(int fd) {
  char path[4096];
  char resolved[4096];
  const char *target = getenv("SOLARA_DISCOVERY_FAULT_ROOT");
  return target && realpath(target, resolved) && fcntl(fd, F_GETPATH, path) == 0 && strcmp(path, resolved) == 0;
}

static int target_parent_fd(int fd) {
  char path[4096];
  char resolved[4096];
  const char *target = getenv("SOLARA_DISCOVERY_FAULT_PARENT");
  return target && realpath(target, resolved) && fcntl(fd, F_GETPATH, path) == 0 && strcmp(path, resolved) == 0;
}

static int fault_open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list args;
    va_start(args, flags);
    mode = va_arg(args, int);
    va_end(args);
  }
  const char *target = getenv("SOLARA_DISCOVERY_FAULT_PARENT");
  if (fault_mode == 5 && target && strcmp(path, target) == 0) {
    fault_hits++;
    errno = EIO;
    return -1;
  }
  return open(path, flags, mode);
}

static struct dirent *fault_readdir(DIR *stream) {
  if (fault_mode == 1 && target_fd(dirfd(stream))) {
    fault_hits++;
    errno = EIO;
    return NULL;
  }
  struct dirent *entry = readdir(stream);
  if (fault_mode == 3 && entry && target_fd(dirfd(stream))) {
    fault_hits++;
    errno = EIO;
  }
  return entry;
}

static int fault_fstatat(int fd, const char *name, struct stat *info, int flags) {
  if (fault_mode == 4 && strcmp(name, ".folder.icloud") == 0 && target_parent_fd(fd)) {
    fault_hits++;
    errno = EIO;
    return -1;
  }
  const char *target = getenv("SOLARA_DISCOVERY_FAULT_CID");
  if (fault_mode == 2 && target && strcmp(target, name) == 0 && target_fd(fd)) {
    fault_hits++;
    errno = EIO;
    return -1;
  }
  return fstatat(fd, name, info, flags);
}

static CFDictionaryRef fault_resource_values(CFURLRef url, CFArrayRef keys, CFErrorRef *error) {
  const char *target = getenv("SOLARA_DISCOVERY_FAULT_ROOT");
  char path[4096];
  if (fault_mode >= 6 && target && CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)) && strcmp(path, target) == 0) {
    fault_hits++;
    if (fault_mode == 6) {
      if (error) *error = CFErrorCreate(NULL, kCFErrorDomainPOSIX, EIO, NULL);
      return NULL;
    }
    if (fault_mode == 7) {
      const void *key = kCFURLIsUbiquitousItemKey;
      const void *value = kCFBooleanTrue;
      return CFDictionaryCreate(NULL, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    return CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  }
  return CFURLCopyResourcePropertiesForKeys(url, keys, error);
}

static id fault_objc_resource_values(id object, SEL selector, id keys, id *error) {
  const char *target = getenv("SOLARA_DISCOVERY_FAULT_ROOT");
  char path[4096];
  if (fault_mode >= 6 && target && CFURLGetFileSystemRepresentation((CFURLRef)object, true, (UInt8 *)path, sizeof(path)) && strcmp(path, target) == 0) {
    return (id)fault_resource_values((CFURLRef)object, (CFArrayRef)keys, (CFErrorRef *)error);
  }
  return ((id (*)(id, SEL, id, id *))original_resource_values)(object, selector, keys, error);
}

__attribute__((used)) static const struct {
  const void *replacement;
  const void *replacee;
} interpositions[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void *)fault_open, (const void *)open},
  {(const void *)fault_readdir, (const void *)readdir},
  {(const void *)fault_fstatat, (const void *)fstatat}
};
