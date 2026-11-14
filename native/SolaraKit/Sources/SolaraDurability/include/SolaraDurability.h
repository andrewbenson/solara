#ifndef SOLARA_DURABILITY_H
#define SOLARA_DURABILITY_H

#include <sqlite3.h>

typedef struct SDScope SDScope;

struct SDScope {
  int (*full_sync)(int, int, void *);
  int (*fallback_sync)(int, void *);
  void *context;
  int failed_errno;
  int fallback_errno;
  sqlite3 *db;
  SDScope *previous;
  sqlite3_file *main_file;
  int synced_db;
  int active;
};

int sd_register(void);
int sd_begin(sqlite3 *, SDScope *);
int sd_finish(SDScope *);
void sd_end(SDScope *);
int sd_generation(sqlite3 *, sqlite3_int64 *);

#endif
