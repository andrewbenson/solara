#include "SolaraDurability.h"
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  sqlite3_file file;
  sqlite3_file *underlying;
  sqlite3_file *database;
  const char *name;
  int flags;
  uint64_t generation;
  sqlite3_io_methods methods;
} SDFile;

typedef struct {
  int calls;
  int fd;
  struct stat info;
} SDCapture;

static sqlite3_vfs sd_vfs;
static sqlite3_vfs *sd_unix;
static _Atomic int sd_registration = SQLITE_ERROR;
static int (*sd_original_fstat)(int, struct stat *);
static _Thread_local SDScope *sd_scope;
static _Thread_local SDCapture *sd_capture;

static int sd_fstat(int fd, struct stat *info) {
  int result = sd_original_fstat(fd, info);
  int saved = errno;
  if (result == 0 && sd_capture) {
    sd_capture->calls++;
    sd_capture->fd = fd;
    sd_capture->info = *info;
  }
  errno = saved;
  return result;
}

static int sd_full_sync(int fd, int command, void *context) {
  (void)context;
  return fcntl(fd, command, 0);
}

static int sd_fallback_sync(int fd, void *context) {
  (void)context;
  return fsync(fd);
}

static int sd_failure(SDScope *scope, int error, int fallback) {
  if (!scope->failed_errno) {
    scope->failed_errno = error ? error : EIO;
    scope->fallback_errno = fallback;
  }
  sqlite3_log(SQLITE_IOERR_FSYNC, "Solara durability sync failed: errno=%d fallback_errno=%d", error, fallback);
  fprintf(stderr, "Solara durability sync failed: errno=%d fallback_errno=%d\n", error, fallback);
  return SQLITE_IOERR_FSYNC;
}

static int sd_sync(sqlite3_file *file, int flags) {
  SDFile *wrapped = (SDFile *)file;
  int result = wrapped->underlying->pMethods->xSync(wrapped->underlying, flags);
  SDScope *scope = sd_scope;
  if (result != SQLITE_OK || !scope || wrapped->database != scope->main_file ||
      !(wrapped->flags & (SQLITE_OPEN_MAIN_DB | SQLITE_OPEN_WAL))) return result;
  SDCapture capture = {0};
  SDCapture *previous = sd_capture;
  sqlite3_int64 size = 0;
  sd_capture = &capture;
  result = wrapped->underlying->pMethods->xFileSize(wrapped->underlying, &size);
  sd_capture = previous;
  if (result != SQLITE_OK) return sd_failure(scope, EIO, 0);
  if (capture.calls != 1 || !S_ISREG(capture.info.st_mode)) return sd_failure(scope, ENOTSUP, 0);
  struct stat named;
  if (!wrapped->name || stat(wrapped->name, &named) != 0) return sd_failure(scope, errno ? errno : ESTALE, 0);
  if (capture.info.st_dev != named.st_dev || capture.info.st_ino != named.st_ino ||
      capture.info.st_size != size) return sd_failure(scope, ESTALE, 0);
  int (*full)(int, int, void *) = scope->full_sync ? scope->full_sync : sd_full_sync;
  do {
    result = full(capture.fd, F_FULLFSYNC, scope->context);
  } while (result != 0 && errno == EINTR);
  if (result != 0) {
    int full_error = errno;
    int (*fallback)(int, void *) = scope->fallback_sync ? scope->fallback_sync : sd_fallback_sync;
    do {
      result = fallback(capture.fd, scope->context);
    } while (result != 0 && errno == EINTR);
    return sd_failure(scope, full_error, result == 0 ? 0 : errno);
  }
  if (file == scope->main_file) scope->synced_db = 1;
  return SQLITE_OK;
}

static int sd_close(sqlite3_file *file) {
  SDFile *wrapped = (SDFile *)file;
  int result = wrapped->underlying->pMethods->xClose(wrapped->underlying);
  file->pMethods = NULL;
  return result;
}

#define SD_IO(name, parameters, arguments) \
  static int sd_##name parameters { \
    SDFile *wrapped = (SDFile *)file; \
    return wrapped->underlying->pMethods->x##name arguments; \
  }

SD_IO(Read, (sqlite3_file *file, void *buffer, int amount, sqlite3_int64 offset), (wrapped->underlying, buffer, amount, offset))
SD_IO(FileSize, (sqlite3_file *file, sqlite3_int64 *size), (wrapped->underlying, size))
SD_IO(Lock, (sqlite3_file *file, int lock), (wrapped->underlying, lock))
SD_IO(Unlock, (sqlite3_file *file, int lock), (wrapped->underlying, lock))
SD_IO(CheckReservedLock, (sqlite3_file *file, int *result), (wrapped->underlying, result))
SD_IO(SectorSize, (sqlite3_file *file), (wrapped->underlying))
SD_IO(DeviceCharacteristics, (sqlite3_file *file), (wrapped->underlying))
SD_IO(ShmMap, (sqlite3_file *file, int page, int size, int extend, void volatile **output), (wrapped->underlying, page, size, extend, output))
SD_IO(ShmLock, (sqlite3_file *file, int offset, int amount, int flags), (wrapped->underlying, offset, amount, flags))
SD_IO(ShmUnmap, (sqlite3_file *file, int remove), (wrapped->underlying, remove))
SD_IO(Fetch, (sqlite3_file *file, sqlite3_int64 offset, int amount, void **output), (wrapped->underlying, offset, amount, output))
SD_IO(Unfetch, (sqlite3_file *file, sqlite3_int64 offset, void *buffer), (wrapped->underlying, offset, buffer))

static void sd_changed(SDFile *wrapped) {
  if (wrapped->database && (wrapped->flags & (SQLITE_OPEN_MAIN_DB | SQLITE_OPEN_WAL))) {
    ((SDFile *)wrapped->database)->generation++;
  }
}

static int sd_Write(sqlite3_file *file, const void *buffer, int amount, sqlite3_int64 offset) {
  SDFile *wrapped = (SDFile *)file;
  int result = wrapped->underlying->pMethods->xWrite(wrapped->underlying, buffer, amount, offset);
  if (result == SQLITE_OK) sd_changed(wrapped);
  return result;
}

static int sd_Truncate(sqlite3_file *file, sqlite3_int64 size) {
  SDFile *wrapped = (SDFile *)file;
  int result = wrapped->underlying->pMethods->xTruncate(wrapped->underlying, size);
  if (result == SQLITE_OK) sd_changed(wrapped);
  return result;
}

static void sd_ShmBarrier(sqlite3_file *file) {
  SDFile *wrapped = (SDFile *)file;
  wrapped->underlying->pMethods->xShmBarrier(wrapped->underlying);
}

static int sd_control(sqlite3_file *file, int operation, void *argument) {
  SDFile *wrapped = (SDFile *)file;
  if (operation == SQLITE_FCNTL_FILE_POINTER) {
    *(sqlite3_file **)argument = file;
    return SQLITE_OK;
  }
  if (operation == SQLITE_FCNTL_VFS_POINTER) {
    *(sqlite3_vfs **)argument = &sd_vfs;
    return SQLITE_OK;
  }
  return wrapped->underlying->pMethods->xFileControl(wrapped->underlying, operation, argument);
}

#define SD_METHODS(version, map, lock, barrier, unmap, fetch, unfetch) \
  { version, sd_close, sd_Read, sd_Write, sd_Truncate, sd_sync, sd_FileSize, sd_Lock, sd_Unlock, \
    sd_CheckReservedLock, sd_control, sd_SectorSize, sd_DeviceCharacteristics, map, lock, barrier, unmap, fetch, unfetch }

static const sqlite3_io_methods sd_io3 = SD_METHODS(3, sd_ShmMap, sd_ShmLock, sd_ShmBarrier, sd_ShmUnmap, sd_Fetch, sd_Unfetch);

static int sd_is_wrapped(sqlite3_file *file) {
  return file && file->pMethods && file->pMethods->xSync == sd_sync && file->pMethods->xClose == sd_close;
}

static size_t sd_file_offset(void) {
  size_t alignment = _Alignof(max_align_t);
  return (sizeof(SDFile) + alignment - 1) / alignment * alignment;
}

static int sd_open(sqlite3_vfs *vfs, const char *name, sqlite3_file *file, int flags, int *output) {
  (void)vfs;
  SDFile *wrapped = (SDFile *)file;
  memset(wrapped, 0, sd_file_offset() + (size_t)sd_unix->szOsFile);
  wrapped->underlying = (sqlite3_file *)((char *)file + sd_file_offset());
  wrapped->name = name;
  wrapped->flags = flags;
  if (flags & SQLITE_OPEN_MAIN_DB) wrapped->database = file;
  else if (flags & (SQLITE_OPEN_WAL | SQLITE_OPEN_MAIN_JOURNAL)) wrapped->database = sqlite3_database_file_object(name);
  int result = sd_unix->xOpen(sd_unix, name, wrapped->underlying, flags, output);
  if (wrapped->underlying->pMethods) {
    const sqlite3_io_methods *methods = wrapped->underlying->pMethods;
    int version = methods->iVersion;
    wrapped->methods = sd_io3;
    wrapped->methods.iVersion = version < 3 ? version : 3;
    wrapped->methods.xShmMap = version >= 2 && methods->xShmMap ? sd_ShmMap : NULL;
    wrapped->methods.xShmLock = version >= 2 && methods->xShmLock ? sd_ShmLock : NULL;
    wrapped->methods.xShmBarrier = version >= 2 && methods->xShmBarrier ? sd_ShmBarrier : NULL;
    wrapped->methods.xShmUnmap = version >= 2 && methods->xShmUnmap ? sd_ShmUnmap : NULL;
    wrapped->methods.xFetch = version >= 3 && methods->xFetch ? sd_Fetch : NULL;
    wrapped->methods.xUnfetch = version >= 3 && methods->xUnfetch ? sd_Unfetch : NULL;
    file->pMethods = &wrapped->methods;
  }
  return result;
}

#define SD_VFS(type, name, parameters, arguments) \
  static type sd_vfs_##name parameters { \
    (void)vfs; \
    return sd_unix->x##name arguments; \
  }

SD_VFS(int, Delete, (sqlite3_vfs *vfs, const char *name, int sync), (sd_unix, name, sync))
SD_VFS(int, Access, (sqlite3_vfs *vfs, const char *name, int flags, int *output), (sd_unix, name, flags, output))
SD_VFS(int, FullPathname, (sqlite3_vfs *vfs, const char *name, int size, char *output), (sd_unix, name, size, output))
SD_VFS(void *, DlOpen, (sqlite3_vfs *vfs, const char *name), (sd_unix, name))
SD_VFS(int, Randomness, (sqlite3_vfs *vfs, int size, char *output), (sd_unix, size, output))
SD_VFS(int, Sleep, (sqlite3_vfs *vfs, int microseconds), (sd_unix, microseconds))
SD_VFS(int, CurrentTime, (sqlite3_vfs *vfs, double *output), (sd_unix, output))
SD_VFS(int, GetLastError, (sqlite3_vfs *vfs, int size, char *output), (sd_unix, size, output))
SD_VFS(int, CurrentTimeInt64, (sqlite3_vfs *vfs, sqlite3_int64 *output), (sd_unix, output))
SD_VFS(int, SetSystemCall, (sqlite3_vfs *vfs, const char *name, sqlite3_syscall_ptr function), (sd_unix, name, function))
SD_VFS(sqlite3_syscall_ptr, GetSystemCall, (sqlite3_vfs *vfs, const char *name), (sd_unix, name))
SD_VFS(const char *, NextSystemCall, (sqlite3_vfs *vfs, const char *name), (sd_unix, name))

static void sd_vfs_DlError(sqlite3_vfs *vfs, int size, char *output) {
  (void)vfs;
  sd_unix->xDlError(sd_unix, size, output);
}

static void (*sd_vfs_DlSym(sqlite3_vfs *vfs, void *handle, const char *name))(void) {
  (void)vfs;
  return sd_unix->xDlSym(sd_unix, handle, name);
}

static void sd_vfs_DlClose(sqlite3_vfs *vfs, void *handle) {
  (void)vfs;
  sd_unix->xDlClose(sd_unix, handle);
}

__attribute__((constructor)) static void sd_initialize(void) {
  sd_registration = sqlite3_initialize();
  if (sd_registration != SQLITE_OK) return;
  sd_unix = sqlite3_vfs_find("unix");
  if (!sd_unix || sd_unix->iVersion < 3 || !sd_unix->xSetSystemCall || !sd_unix->xGetSystemCall) {
    sd_registration = SQLITE_NOTFOUND;
    return;
  }
  sd_original_fstat = (int (*)(int, struct stat *))sd_unix->xGetSystemCall(sd_unix, "fstat");
  if (sd_original_fstat != fstat) {
    sd_registration = SQLITE_NOTFOUND;
    return;
  }
  sd_registration = sd_unix->xSetSystemCall(sd_unix, "fstat", (sqlite3_syscall_ptr)sd_fstat);
  if (sd_registration != SQLITE_OK) return;
  if (sd_unix->xGetSystemCall(sd_unix, "fstat") != (sqlite3_syscall_ptr)sd_fstat) {
    sd_registration = SQLITE_NOTFOUND;
    return;
  }
  sd_vfs = (sqlite3_vfs){
    .iVersion = 3,
    .szOsFile = (int)sd_file_offset() + sd_unix->szOsFile,
    .mxPathname = sd_unix->mxPathname,
    .zName = "solara-durable",
    .xOpen = sd_open,
    .xDelete = sd_vfs_Delete,
    .xAccess = sd_vfs_Access,
    .xFullPathname = sd_vfs_FullPathname,
    .xDlOpen = sd_vfs_DlOpen,
    .xDlError = sd_vfs_DlError,
    .xDlSym = sd_vfs_DlSym,
    .xDlClose = sd_vfs_DlClose,
    .xRandomness = sd_vfs_Randomness,
    .xSleep = sd_vfs_Sleep,
    .xCurrentTime = sd_vfs_CurrentTime,
    .xGetLastError = sd_vfs_GetLastError,
    .xCurrentTimeInt64 = sd_unix->xCurrentTimeInt64 ? sd_vfs_CurrentTimeInt64 : NULL,
    .xSetSystemCall = sd_vfs_SetSystemCall,
    .xGetSystemCall = sd_vfs_GetSystemCall,
    .xNextSystemCall = sd_unix->xNextSystemCall ? sd_vfs_NextSystemCall : NULL,
  };
  sd_registration = sqlite3_vfs_register(&sd_vfs, 0);
}

int sd_register(void) {
  int result = sd_registration;
  if (result != SQLITE_OK) return result;
  if (sd_unix->xGetSystemCall(sd_unix, "fstat") != (sqlite3_syscall_ptr)sd_fstat) {
    sd_registration = SQLITE_NOTFOUND;
    return SQLITE_NOTFOUND;
  }
  return SQLITE_OK;
}

int sd_begin(sqlite3 *db, SDScope *scope) {
  if (!db || !scope || sd_scope == scope) return SQLITE_MISUSE;
  scope->failed_errno = 0;
  scope->fallback_errno = 0;
  scope->synced_db = 0;
  scope->active = 0;
  scope->main_file = NULL;
  scope->previous = NULL;
  scope->db = db;
  int result = sd_register();
  if (result != SQLITE_OK) return result;
  result = sqlite3_file_control(db, "main", SQLITE_FCNTL_FILE_POINTER, &scope->main_file);
  if (result != SQLITE_OK) return result;
  if (!sd_is_wrapped(scope->main_file)) return SQLITE_NOTFOUND;
  scope->previous = sd_scope;
  scope->active = 1;
  sd_scope = scope;
  return SQLITE_OK;
}

int sd_finish(SDScope *scope) {
  if (!scope || sd_scope != scope || !scope->active) return SQLITE_MISUSE;
  int result = scope->failed_errno ? SQLITE_IOERR_FSYNC : SQLITE_OK;
  if (result == SQLITE_OK && !scope->synced_db) result = scope->main_file->pMethods->xSync(scope->main_file, SQLITE_SYNC_NORMAL);
  sd_end(scope);
  return result;
}

void sd_end(SDScope *scope) {
  if (scope && sd_scope == scope && scope->active) {
    sd_scope = scope->previous;
    scope->previous = NULL;
    scope->active = 0;
  }
}

int sd_generation(sqlite3 *db, sqlite3_int64 *output) {
  if (!db || !output) return SQLITE_MISUSE;
  int result = sd_register();
  if (result != SQLITE_OK) return result;
  sqlite3_file *file = NULL;
  result = sqlite3_file_control(db, "main", SQLITE_FCNTL_FILE_POINTER, &file);
  if (result != SQLITE_OK) return result;
  if (!sd_is_wrapped(file)) return SQLITE_NOTFOUND;
  memcpy(output, &((SDFile *)file)->generation, sizeof(*output));
  return SQLITE_OK;
}
