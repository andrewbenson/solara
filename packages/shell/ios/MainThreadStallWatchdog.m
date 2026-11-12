#if DEBUG || SOLARA_STALL_BENCH
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <mach/mach_vm.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <pthread.h>
#import <stdatomic.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <limits.h>
#import <string.h>
#import <stdio.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

#define STALL_RING_SIZE 2048
#define STALL_FRAME_LIMIT 32

static const uint64_t StallMinimumNs = 8000000;
typedef struct {
  uint64_t identifier, start, duration;
  uintptr_t frames[STALL_FRAME_LIMIT];
  int frameCount;
  char checkpoint[129];
} StallEvent;
typedef struct {
  uint64_t identifier, at;
  uintptr_t frames[STALL_FRAME_LIMIT];
  int frameCount;
  kern_return_t resumeStatus;
} StallSample;
static StallEvent stallRing[STALL_RING_SIZE];
static _Atomic uint64_t stallHead, stallTail, stallDropped;
static _Atomic uint64_t stallActive, stallCompleting;
static _Atomic bool stallSleeping;
static uint64_t stallMainStart;
static unsigned stallDepth;
static _Atomic bool stallReady;
static thread_t stallMainThread;
static uintptr_t stallStackLow, stallStackHigh;
static mach_timebase_info_data_t stallTimebase;
static dispatch_semaphore_t stallWake;
static NSString *stallDirectory, *stallSession;
static uint64_t stallOrigin;
static double stallEpoch;
static int stallLockFD = -1;

static uint64_t StallNow(void) {
  uint64_t value = mach_absolute_time();
  return (uint64_t)((__uint128_t)value * stallTimebase.numer / stallTimebase.denom);
}

static double StallEpochMs(uint64_t value) {
  return stallEpoch + (double)(value - stallOrigin) / 1e6;
}

static void StallWakeWatcher(void) {
  if (atomic_exchange_explicit(&stallSleeping, false, memory_order_acq_rel)) dispatch_semaphore_signal(stallWake);
}

static void StallBegin(void) {
  if (stallMainStart) return;
  stallMainStart = StallNow();
  atomic_store_explicit(&stallActive, stallMainStart, memory_order_release);
  StallWakeWatcher();
}

static void StallEnd(void) {
  if (!stallMainStart) return;
  atomic_store_explicit(&stallCompleting, stallMainStart, memory_order_release);
  uint64_t end = StallNow(), duration = end - stallMainStart;
  if (duration > StallMinimumNs) {
    uint64_t head = atomic_load_explicit(&stallHead, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&stallTail, memory_order_acquire);
    if (head - tail < STALL_RING_SIZE) {
      StallEvent *event = &stallRing[head % STALL_RING_SIZE];
      event->identifier = stallMainStart;
      event->start = stallMainStart;
      event->duration = duration;
      event->frameCount = backtrace((void **)event->frames, STALL_FRAME_LIMIT);
      atomic_store_explicit(&stallHead, head + 1, memory_order_release);
    } else atomic_fetch_add_explicit(&stallDropped, 1, memory_order_relaxed);
  }
  atomic_store_explicit(&stallActive, 0, memory_order_release);
  atomic_store_explicit(&stallCompleting, 0, memory_order_release);
  stallMainStart = 0;
  if (duration > StallMinimumNs) dispatch_semaphore_signal(stallWake);
}

static void StallCheckpoint(NSString *identifier) {
  CFRunLoopObserverRef checkpoint = CFRunLoopObserverCreateWithHandler(NULL, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, LONG_MAX - 8,
      ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
    if (atomic_load_explicit(&stallActive, memory_order_acquire)) return;
    uint64_t head = atomic_load_explicit(&stallHead, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&stallTail, memory_order_acquire);
    if (head - tail < STALL_RING_SIZE) {
      StallEvent *event = &stallRing[head % STALL_RING_SIZE];
      memset(event, 0, sizeof *event);
      event->start = StallNow();
      event->frameCount = -1;
      event->identifier = atomic_load_explicit(&stallActive, memory_order_acquire);
      strlcpy(event->checkpoint, identifier.UTF8String, sizeof event->checkpoint);
      atomic_store_explicit(&stallHead, head + 1, memory_order_release);
    } else atomic_fetch_add_explicit(&stallDropped, 1, memory_order_relaxed);
    dispatch_semaphore_signal(stallWake);
    CFRunLoopObserverInvalidate(observer);
  });
  if (!checkpoint) return;
  CFRunLoopAddObserver(CFRunLoopGetMain(), checkpoint, kCFRunLoopCommonModes);
  CFRelease(checkpoint);
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

static void StallLoopActivity(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *context) {
  if (activity == kCFRunLoopEntry) {
    stallDepth++;
    StallBegin();
  } else if (activity == kCFRunLoopAfterWaiting) {
    StallBegin();
  } else if (activity == kCFRunLoopBeforeWaiting) {
    StallEnd();
  } else if (activity == kCFRunLoopExit) {
    if (stallDepth) stallDepth--;
    if (stallDepth) StallBegin();
    else StallEnd();
  }
}

static uintptr_t StallReturnAddress(uintptr_t value) {
#if __has_feature(ptrauth_calls)
  return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_return_address);
#else
  return value;
#endif
}

static BOOL StallReadFrame(uintptr_t address, uintptr_t pair[2]) {
  if (address < stallStackLow || address > stallStackHigh - sizeof(uintptr_t) * 2 || address % sizeof(uintptr_t)) return NO;
  mach_vm_size_t read = 0;
  return mach_vm_read_overwrite(mach_task_self(), address, sizeof(uintptr_t) * 2, (mach_vm_address_t)pair, &read) == KERN_SUCCESS && read == sizeof(uintptr_t) * 2;
}

static BOOL StallSampleMatches(const StallSample *sample, const StallEvent *event) {
  return sample->identifier == event->identifier && sample->frameCount > 0 && sample->at >= event->start && sample->at - event->start <= event->duration;
}

static StallSample StallCapture(uint64_t identifier) {
  StallSample sample = { .identifier = identifier };
  if (thread_suspend(stallMainThread) != KERN_SUCCESS) return sample;
  sample.at = StallNow();
  if (atomic_load_explicit(&stallActive, memory_order_acquire) == identifier &&
      atomic_load_explicit(&stallCompleting, memory_order_acquire) != identifier) {
    uintptr_t frame = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(stallMainThread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
      sample.frames[sample.frameCount++] = __darwin_arm_thread_state64_get_pc(state);
      sample.frames[sample.frameCount++] = StallReturnAddress(__darwin_arm_thread_state64_get_lr(state));
      frame = __darwin_arm_thread_state64_get_fp(state);
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(stallMainThread, x86_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
      sample.frames[sample.frameCount++] = state.__rip;
      frame = state.__rbp;
    }
#endif
    while (frame && sample.frameCount < STALL_FRAME_LIMIT) {
      uintptr_t pair[2];
      if (!StallReadFrame(frame, pair)) break;
      sample.frames[sample.frameCount++] = StallReturnAddress(pair[1]);
      if (pair[0] <= frame || pair[0] - frame > 1024 * 1024) break;
      frame = pair[0];
    }
  }
  sample.resumeStatus = thread_resume(stallMainThread);
  return sample;
}

static NSString *StallImageUUID(const struct mach_header *header) {
  if (!header || header->magic != MH_MAGIC_64) return @"unknown";
  const struct mach_header_64 *h = (const struct mach_header_64 *)header;
  const uint8_t *cursor = (const uint8_t *)(h + 1);
  const uint8_t *end = cursor + h->sizeofcmds;
  for (uint32_t i = 0; i < h->ncmds && cursor + sizeof(struct load_command) <= end; i++) {
    const struct load_command *command = (const struct load_command *)cursor;
    if (command->cmdsize < sizeof *command || cursor + command->cmdsize > end) break;
    if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
      return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
    }
    cursor += command->cmdsize;
  }
  return @"unknown";
}

static NSArray *StallFrames(const uintptr_t *frames, int count) {
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
  for (int i = 0; i < count; i++) {
    uintptr_t address = frames[i];
    Dl_info info = {0};
    if (dladdr((void *)(address > 0 && i > 0 ? address - 1 : address), &info) && info.dli_fbase) {
      [result addObject:@{@"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address],
                         @"image": info.dli_fname ? @(info.dli_fname).lastPathComponent : @"unknown",
                         @"uuid": StallImageUUID(info.dli_fbase),
                         @"offset": [NSString stringWithFormat:@"0x%llx", (unsigned long long)(address - (uintptr_t)info.dli_fbase)],
                         @"symbol": info.dli_sname ? @(info.dli_sname) : @""}];
    } else [result addObject:@{@"address": [NSString stringWithFormat:@"0x%llx", (unsigned long long)address], @"uuid": @"unknown"}];
  }
  return result;
}

static NSDictionary *StallState(uint64_t count, uint64_t totalNs, BOOL ioError, double watermark, uint64_t activeStart) {
  return @{@"schema": @1, @"pid": @(getpid()), @"session": stallSession,
           @"ready": @(atomic_load_explicit(&stallReady, memory_order_acquire)), @"startedMs": @(stallEpoch),
           @"count": @(count), @"totalMs": @((double)totalNs / 1e6),
           @"dropped": @(atomic_load_explicit(&stallDropped, memory_order_relaxed)), @"ioError": @(ioError),
           @"updatedMs": @(StallEpochMs(StallNow())), @"completedThroughMs": @(watermark),
           @"activeStartMs": activeStart ? @(StallEpochMs(activeStart)) : NSNull.null};
}

static BOOL StallWriteLine(FILE *file, NSDictionary *record) {
  NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
  return json && fwrite(json.bytes, 1, json.length, file) == json.length && fputc('\n', file) != EOF;
}

static BOOL StallRotate(FILE **file, NSString *path) {
  if (!*file || ftello(*file) < 16 * 1024 * 1024) return *file != NULL;
  if (fclose(*file)) { *file = NULL; return NO; }
  *file = NULL;
  NSFileManager *manager = NSFileManager.defaultManager;
  NSString *oldest = [path stringByAppendingString:@".3"];
  if ([manager fileExistsAtPath:oldest] && ![manager removeItemAtPath:oldest error:nil]) return NO;
  for (int i = 2; i >= 0; i--) {
    NSString *source = i ? [path stringByAppendingFormat:@".%d", i] : path;
    NSString *destination = [path stringByAppendingFormat:@".%d", i + 1];
    if ([manager fileExistsAtPath:source] && ![manager moveItemAtPath:source toPath:destination error:nil]) return NO;
  }
  int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return NO;
  *file = fdopen(fd, "a");
  if (!*file) { close(fd); return NO; }
  return StallWriteLine(*file, @{@"schema": @1, @"kind": @"session", @"session": stallSession, @"pid": @(getpid()), @"startMs": @(stallEpoch)});
}

static void *StallWatch(void *unused) {
  pthread_setname_np("solara.main-stall-watchdog");
  @autoreleasepool {
    NSString *logPath = [stallDirectory stringByAppendingPathComponent:@"main-thread-stalls.jsonl"];
    int fd = open(logPath.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    FILE *log = fd >= 0 ? fdopen(fd, "a") : NULL;
    if (!log && fd >= 0) close(fd);
    BOOL ioError = log == NULL;
    uint64_t count = 0, totalNs = 0, sampledIdentifier = 0;
    StallSample sample = {0};
    NSString *lastRequest;
    BOOL pendingRequest = NO;
    uint64_t lastStateAt = 0, lastRequestPoll = 0;
    if (log) ioError = !StallWriteLine(log, @{@"schema": @1, @"kind": @"session", @"session": stallSession, @"pid": @(getpid()), @"startMs": @(stallEpoch)});
    for (;;) {
      @autoreleasepool {
        uint64_t before = StallNow();
        uint64_t identifier = atomic_load_explicit(&stallActive, memory_order_acquire);
        uint64_t activeStart = identifier;
        uint64_t head = atomic_load_explicit(&stallHead, memory_order_acquire);
        uint64_t tail = atomic_load_explicit(&stallTail, memory_order_relaxed);
        BOOL dirty = tail < head;
        for (; tail < head; tail++) {
          StallEvent *event = &stallRing[tail % STALL_RING_SIZE];
          if (event->frameCount == -1) {
            if (log && fflush(log)) ioError = YES;
            NSMutableDictionary *response = [StallState(count, totalNs, ioError, StallEpochMs(event->start), event->identifier) mutableCopy];
            response[@"id"] = @(event->checkpoint);
            NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
            if (![data writeToFile:[stallDirectory stringByAppendingPathComponent:@"main-thread-stalls-response.json"] options:NSDataWritingAtomic error:nil]) ioError = YES;
            pendingRequest = NO;
            continue;
          }
          BOOL liveSample = StallSampleMatches(&sample, event);
          NSDictionary *record = @{@"schema": @1, @"kind": @"stall", @"session": stallSession, @"pid": @(getpid()),
                                   @"span": @(event->identifier), @"startMs": @(StallEpochMs(event->start)), @"startMonotonicMs": @((double)event->start / 1e6),
                                   @"durationMs": @((double)event->duration / 1e6),
                                   @"sampleKind": liveSample ? @"threshold-stack" : @"completion",
                                   @"sampleAtMs": @(StallEpochMs(liveSample ? sample.at : event->start + event->duration)),
                                   @"frames": StallFrames(liveSample ? sample.frames : event->frames, liveSample ? sample.frameCount : event->frameCount)};
          if (!StallRotate(&log, logPath) || !StallWriteLine(log, record)) ioError = YES;
          count++;
          totalNs += event->duration;
        }
        atomic_store_explicit(&stallTail, tail, memory_order_release);
        if (log && fflush(log)) ioError = YES;
        double watermark = StallEpochMs(identifier ? MIN(before, activeStart) : before);
        if (dirty || before - lastStateAt >= 1000000000) {
          NSDictionary *state = StallState(count, totalNs, ioError, watermark, identifier ? activeStart : 0);
          NSData *stateData = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
          NSString *statePath = [stallDirectory stringByAppendingPathComponent:@"main-thread-stalls-state.json"];
          if (![stateData writeToFile:statePath options:NSDataWritingAtomic error:nil]) ioError = YES;
          lastStateAt = before;
        }
        if (!pendingRequest && before - lastRequestPoll >= 100000000) {
          lastRequestPoll = before;
          NSData *requestData = [NSData dataWithContentsOfFile:[stallDirectory stringByAppendingPathComponent:@"main-thread-stalls-request.json"]];
          id request = requestData ? [NSJSONSerialization JSONObjectWithData:requestData options:0 error:nil] : nil;
          id requestID = [request isKindOfClass:NSDictionary.class] ? request[@"id"] : nil;
          if ([requestID isKindOfClass:NSString.class] && [requestID lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 0 &&
              [requestID lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 128 && [request[@"pid"] intValue] == getpid() && ![requestID isEqual:lastRequest]) {
            lastRequest = [requestID copy];
            pendingRequest = YES;
            StallCheckpoint(lastRequest);
          }
        }
        uint64_t delay = 100000000;
        if (identifier) {
          uint64_t elapsed = StallNow() - activeStart;
          if (elapsed >= StallMinimumNs && sampledIdentifier != identifier) {
            sample = StallCapture(identifier);
            if (sample.resumeStatus != KERN_SUCCESS) ioError = YES;
            sampledIdentifier = identifier;
            if (sample.frameCount) {
              NSDictionary *activeRecord = @{@"schema": @1, @"kind": @"sample", @"session": stallSession, @"pid": @(getpid()),
                                            @"span": @(identifier), @"startMs": @(StallEpochMs(activeStart)),
                                            @"sampleAtMs": @(StallEpochMs(sample.at)), @"durationMs": @((double)(sample.at - activeStart) / 1e6),
                                            @"sampleKind": @"threshold-stack", @"frames": StallFrames(sample.frames, sample.frameCount)};
              if (!StallRotate(&log, logPath) || !StallWriteLine(log, activeRecord) || fflush(log)) ioError = YES;
            }
          }
          if (elapsed < StallMinimumNs) delay = StallMinimumNs - elapsed;
        }
        atomic_store_explicit(&stallSleeping, identifier == 0, memory_order_release);
        if (head != atomic_load_explicit(&stallHead, memory_order_acquire) || identifier != atomic_load_explicit(&stallActive, memory_order_acquire)) {
          atomic_store_explicit(&stallSleeping, false, memory_order_release);
          continue;
        }
        dispatch_semaphore_wait(stallWake, dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay));
        atomic_store_explicit(&stallSleeping, false, memory_order_release);
      }
    }
  }
  return NULL;
}

static void StallInstall(NSString *directory) {
  if (![NSThread isMainThread] || stallWake) return;
  if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil]) return;
  NSString *lockPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"main-thread-stalls-%d.lock", getpid()]];
  stallLockFD = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (stallLockFD < 0 || flock(stallLockFD, LOCK_EX | LOCK_NB)) {
    if (stallLockFD >= 0) close(stallLockFD);
    stallLockFD = -1;
    return;
  }
  stallDirectory = [directory copy];
  stallSession = NSUUID.UUID.UUIDString;
  mach_timebase_info(&stallTimebase);
  stallOrigin = StallNow();
  stallEpoch = NSDate.date.timeIntervalSince1970 * 1000;
  stallMainThread = mach_thread_self();
  stallStackHigh = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
  stallStackLow = stallStackHigh - pthread_get_stacksize_np(pthread_self());
  stallWake = dispatch_semaphore_create(0);
  pthread_t watcher;
  if (pthread_create(&watcher, NULL, StallWatch, NULL)) return;
  pthread_detach(watcher);
  CFRunLoopObserverRef observer = CFRunLoopObserverCreate(NULL, kCFRunLoopEntry | kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                        true, LONG_MAX - 16, StallLoopActivity, NULL);
  if (observer) {
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
    CFStringRef currentMode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
    stallDepth = currentMode ? 1 : 0;
    if (currentMode) CFRelease(currentMode);
    atomic_store_explicit(&stallReady, true, memory_order_release);
    StallBegin();
  }
}

#if !SOLARA_STALL_TEST
#if SOLARA_STALL_BENCH
#define StallLoaderClass SolaraBenchMainThreadStallWatchdog
#else
#define StallLoaderClass SolaraMainThreadStallWatchdog
#endif
@interface StallLoaderClass : NSObject
@end
@implementation StallLoaderClass
+ (void)load {
  @autoreleasepool {
#if DEBUG
    const char *enabled = getenv("SOLARA_STALL_WATCHDOG");
    if (enabled && !strcmp(enabled, "0")) return;
#endif
    NSString *path = NSBundle.mainBundle.bundlePath;
    if (![path hasSuffix:@".app"] || [path containsString:@"Helper"]) return;
#if SOLARA_STALL_BENCH
    if (!getenv("SOLARA_DATA_DIR")) return;
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *directory = NSProcessInfo.processInfo.environment[@"SOLARA_DATA_DIR"];
      if (!directory) {
        NSURL *base = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        directory = [[base URLByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"Solara" isDirectory:YES] path];
      }
      if (directory) StallInstall(directory);
    });
  }
}
@end
#endif
#endif
