#include "SolaraDurability.h"
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static void sql(sqlite3 *db, const char *text) {
  int result = sqlite3_exec(db, text, NULL, NULL, NULL);
  if (result != SQLITE_OK) fprintf(stderr, "SQL %d: %s\n", result, sqlite3_errmsg(db));
  assert(result == SQLITE_OK);
}

int main(int argc, char **argv) {
  assert(argc == 3);
  int unavailable = strcmp(argv[1], "available") != 0;
  sqlite3_vfs *registered = sqlite3_vfs_find("solara-durable");
  if (!unavailable) assert(registered != NULL);
  int registration = sd_register();
  if (unavailable) {
    assert(registration != SQLITE_OK);
    assert(sd_register() == registration);
    sqlite3 *ordinary = NULL;
    assert(sqlite3_open(argv[2], &ordinary) == SQLITE_OK);
    sql(ordinary, "PRAGMA journal_mode=WAL; CREATE TABLE t(v); INSERT INTO t VALUES(1)");
    SDScope scope = {0};
    assert(sd_begin(ordinary, &scope) != SQLITE_OK);
    assert(!scope.active);
    assert(sqlite3_close(ordinary) == SQLITE_OK);
    printf("PASS unavailable=%s status=%d ordinary open/write succeeds\n", argv[1], registration);
    return 0;
  }
  assert(registration == SQLITE_OK);
  assert(strcmp(sqlite3_vfs_find(NULL)->zName, "solara-durable") != 0);
  void (*reset)(void) = dlsym(RTLD_DEFAULT, "sd_test_reset");
  int (*count)(int) = dlsym(RTLD_DEFAULT, "sd_test_count");
  const char *(*order)(void) = dlsym(RTLD_DEFAULT, "sd_test_order");
  assert(reset && count && order);
  sqlite3 *db = NULL;
  assert(sqlite3_open_v2(argv[2], &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, "solara-durable") == SQLITE_OK);
  sql(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(v); INSERT INTO t VALUES(1); PRAGMA wal_checkpoint(FULL)");
  reset();
  fprintf(stderr, "BEGIN_ROUTINE\n");
  sql(db, "INSERT INTO t VALUES(2); PRAGMA wal_checkpoint(FULL); INSERT INTO t VALUES(3); PRAGMA wal_checkpoint(TRUNCATE)");
  fprintf(stderr, "END_ROUTINE\n");
  printf("routine barriers=%d full=%d fsync=%d\n", count(0), count(1), count(2));
  assert(count(0) > 0 && count(1) == 0 && count(2) == 0);
  sql(db, "PRAGMA synchronous=FULL");
  reset();
  fprintf(stderr, "BEGIN_DURABLE\n");
  SDScope scope = {0};
  assert(sd_begin(db, &scope) == SQLITE_OK);
  sql(db, "BEGIN; INSERT INTO t VALUES(4); COMMIT; PRAGMA wal_checkpoint(FULL)");
  assert(sd_finish(&scope) == SQLITE_OK);
  fprintf(stderr, "END_DURABLE\n");
  printf("durable barriers=%d full=%d fsync=%d order=%s\n", count(0), count(1), count(2), order());
  assert(count(0) > 0 && count(1) >= 2 && count(2) == 0);
  assert(count(3) == 'W' && count(4) == 'D');
  for (int i = 0; i < count(1) - 1; i++) assert(order()[i] == 'W');
  reset();
  fprintf(stderr, "BEGIN_UNCHANGED\n");
  scope = (SDScope){0};
  assert(sd_begin(db, &scope) == SQLITE_OK);
  sql(db, "PRAGMA wal_checkpoint(FULL)");
  assert(sd_finish(&scope) == SQLITE_OK);
  fprintf(stderr, "END_UNCHANGED\n");
  assert(count(1) == 1 && count(4) == 'D');
  sqlite3_vfs *unix_vfs = sqlite3_vfs_find("unix");
  sqlite3_syscall_ptr installed = unix_vfs->xGetSystemCall(unix_vfs, "fstat");
  assert(unix_vfs->xSetSystemCall(unix_vfs, "fstat", (sqlite3_syscall_ptr)fstat) == SQLITE_OK);
  sqlite3_int64 generation = 0;
  assert(sd_generation(db, &generation) != SQLITE_OK);
  scope = (SDScope){0};
  assert(sd_begin(db, &scope) != SQLITE_OK);
  assert(unix_vfs->xSetSystemCall(unix_vfs, "fstat", installed) == SQLITE_OK);
  assert(sd_register() != SQLITE_OK);
  sql(db, "PRAGMA synchronous=NORMAL; INSERT INTO t VALUES(5); PRAGMA wal_checkpoint(FULL)");
  assert(sqlite3_close(db) == SQLITE_OK);
  puts("PASS routine primitives, durable ordering, unchanged save");
  return 0;
}
