#define SOLARA_STALL_BENCH 1
#define SOLARA_STALL_TEST 1
#import "../ios/MainThreadStallWatchdog.m"
#import <assert.h>

static void BusyMain(double milliseconds) {
  uint64_t end = StallNow() + (uint64_t)(milliseconds * 1e6);
  while (StallNow() < end) __asm__ volatile("" ::: "memory");
}

static NSDictionary *Checkpoint(NSString *directory, NSString *identifier) {
  NSDictionary *request = @{@"id": identifier, @"pid": @(getpid())};
  NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  assert([data writeToFile:[directory stringByAppendingPathComponent:@"main-thread-stalls-request.json"] options:NSDataWritingAtomic error:nil]);
  uint64_t deadline = StallNow() + 3000000000;
  while (StallNow() < deadline) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    NSData *responseData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"main-thread-stalls-response.json"]];
    NSDictionary *response = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
    if ([response[@"id"] isEqual:identifier]) return response;
  }
  assert(false);
  return nil;
}

int main(void) {
  @autoreleasepool {
    StallEvent matchingEvent = { .identifier = 10, .start = 100, .duration = 20 };
    StallSample matchingSample = { .identifier = 10, .at = 120, .frameCount = 1 };
    assert(StallSampleMatches(&matchingSample, &matchingEvent));
    matchingSample.at = 121;
    assert(!StallSampleMatches(&matchingSample, &matchingEvent));
    matchingSample.at = 99;
    assert(!StallSampleMatches(&matchingSample, &matchingEvent));
    matchingSample.at = 110;
    matchingSample.identifier = 11;
    assert(!StallSampleMatches(&matchingSample, &matchingEvent));
    matchingSample.identifier = 10;
    matchingSample.frameCount = 0;
    assert(!StallSampleMatches(&matchingSample, &matchingEvent));
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    StallInstall(directory);
    CFRunLoopTimerRef keepAlive = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent() + 10, 10, 0, 0, ^(CFRunLoopTimerRef timer) {});
    CFRunLoopAddTimer(CFRunLoopGetMain(), keepAlive, kCFRunLoopDefaultMode);
    NSDictionary *initial = Checkpoint(directory, @"initial");
    assert([initial[@"ready"] boolValue]);
    assert([initial[@"dropped"] intValue] == 0);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.15, false);
    NSDictionary *idle = Checkpoint(directory, @"idle");
    assert([idle[@"count"] unsignedLongLongValue] == [initial[@"count"] unsignedLongLongValue]);
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{ BusyMain(20); });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{ BusyMain(80); });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    NSDictionary *busy = Checkpoint(directory, @"busy");
    assert([busy[@"count"] unsignedLongLongValue] >= [idle[@"count"] unsignedLongLongValue] + 2);
    assert([busy[@"totalMs"] doubleValue] - [idle[@"totalMs"] doubleValue] >= 100);
    assert(![busy[@"ioError"] boolValue]);
    NSDictionary *splitBefore = Checkpoint(directory, @"split-before");
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
      BusyMain(4);
      StallCheckpoint(@"mid-turn");
      BusyMain(6);
    });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);
    NSDictionary *splitAfter = Checkpoint(directory, @"split-after");
    assert([splitAfter[@"count"] unsignedLongLongValue] == [splitBefore[@"count"] unsignedLongLongValue] + 1);
    assert([splitAfter[@"totalMs"] doubleValue] - [splitBefore[@"totalMs"] doubleValue] >= 10);
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
      BusyMain(4);
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
      BusyMain(6);
    });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.04, false);
    NSDictionary *nestedNoWait = Checkpoint(directory, @"nested-no-wait");
    assert([nestedNoWait[@"count"] unsignedLongLongValue] == [splitAfter[@"count"] unsignedLongLongValue] + 1);
    assert([nestedNoWait[@"totalMs"] doubleValue] - [splitAfter[@"totalMs"] doubleValue] >= 10);
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
      BusyMain(12);
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
      BusyMain(25);
    });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
    NSDictionary *nested = Checkpoint(directory, @"nested");
    assert([nested[@"count"] unsignedLongLongValue] >= [nestedNoWait[@"count"] unsignedLongLongValue] + 2);
    double nestedMs = [nested[@"totalMs"] doubleValue] - [nestedNoWait[@"totalMs"] doubleValue];
    assert(nestedMs >= 37 && nestedMs < 70);
    NSString *log = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"main-thread-stalls.jsonl"] encoding:NSUTF8StringEncoding error:nil];
    BOOL foundLiveLongStack = NO, foundLiveShortStack = NO;
    for (NSString *line in [log componentsSeparatedByString:@"\n"]) {
      if (!line.length) continue;
      NSDictionary *record = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
      if (![record[@"kind"] isEqual:@"stall"]) continue;
      assert([record[@"durationMs"] doubleValue] > 8);
      assert([record[@"frames"] count] > 0);
      if ([record[@"durationMs"] doubleValue] >= 15 && [record[@"durationMs"] doubleValue] < 50 &&
          [record[@"sampleKind"] isEqual:@"threshold-stack"] && [record[@"frames"] count] > 2) foundLiveShortStack = YES;
      if ([record[@"durationMs"] doubleValue] >= 75 && [record[@"sampleKind"] isEqual:@"threshold-stack"]) foundLiveLongStack = YES;
    }
    assert(foundLiveLongStack);
    assert(foundLiveShortStack);
    CFRunLoopTimerInvalidate(keepAlive);
    CFRelease(keepAlive);
    puts("main-thread stall watchdog: busy, idle, nested, stack and checkpoint checks passed");
  }
  return 0;
}
