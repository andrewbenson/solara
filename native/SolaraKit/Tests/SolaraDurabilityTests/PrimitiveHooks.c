#include <assert.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern int fcntl_nocancel(int, int, ...) __asm("_fcntl$NOCANCEL");
extern int fsync_nocancel(int) __asm("_fsync$NOCANCEL");
static int counts[5];
static char order[128];

void sd_test_reset(void) {
  for (int i = 0; i < 5; i++) counts[i] = 0;
  memset(order, 0, sizeof(order));
}

int sd_test_count(int index) {
  assert(index >= 0 && index < 5);
  return counts[index];
}

const char *sd_test_order(void) {
  return order;
}

static void record(int fd, int kind, int result) {
  char path[1024] = {0};
  fcntl(fd, F_GETPATH, path);
  counts[kind]++;
  if (kind == 1) {
    if (!counts[3]) counts[3] = strstr(path, "-wal") ? 'W' : 'D';
    counts[4] = strstr(path, "-wal") ? 'W' : 'D';
    assert(counts[1] < (int)sizeof(order));
    order[counts[1] - 1] = (char)counts[4];
  }
  fprintf(stderr, "%s,%s,result=%d\n", kind == 0 ? "BARRIER" : kind == 1 ? "FULL" : "FSYNC", path, result);
}

static int traced_fsync(int fd) {
  int result = fsync(fd);
  record(fd, 2, result);
  return result;
}

static int traced_fsync_nocancel(int fd) {
  int result = fsync_nocancel(fd);
  record(fd, 2, result);
  return result;
}

static int intercept(int fd, int command, va_list arguments, int nocancel) {
  uintptr_t argument = 0;
  if (command != F_FULLFSYNC && command != F_BARRIERFSYNC && command != F_GETFD && command != F_GETFL && command != F_GETOWN) argument = va_arg(arguments, uintptr_t);
  int result = nocancel ? fcntl_nocancel(fd, command, argument) : fcntl(fd, command, argument);
  if (command == F_FULLFSYNC || command == F_BARRIERFSYNC) record(fd, command == F_FULLFSYNC ? 1 : 0, result);
  return result;
}

static int traced_fcntl(int fd, int command, ...) {
  va_list arguments;
  va_start(arguments, command);
  int result = intercept(fd, command, arguments, 0);
  va_end(arguments);
  return result;
}

static int traced_fcntl_nocancel(int fd, int command, ...) {
  va_list arguments;
  va_start(arguments, command);
  int result = intercept(fd, command, arguments, 1);
  va_end(arguments);
  return result;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct { const void *replacement; const void *original; } interposers[] = {
  {(const void *)traced_fsync, (const void *)fsync},
  {(const void *)traced_fsync_nocancel, (const void *)fsync_nocancel},
  {(const void *)traced_fcntl, (const void *)fcntl},
  {(const void *)traced_fcntl_nocancel, (const void *)fcntl_nocancel}
};
