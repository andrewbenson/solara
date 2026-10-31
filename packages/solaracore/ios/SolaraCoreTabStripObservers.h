#pragma once

#import <Foundation/Foundation.h>

namespace solaracore_tab_strip {

using Observer = void (^)(NSDictionary *);

class Observers {
 public:
  NSInteger Add(Observer observer) {
    observers_[@(++last_)] = [observer copy];
    return last_;
  }

  void Remove(NSInteger token) { [observers_ removeObjectForKey:@(token)]; }

  void SetHandler(Observer handler) {
    if (handler_) Remove(handler_);
    handler_ = handler ? Add(handler) : 0;
  }

  void ClaimCommands() { claimed_ = true; }

  bool CommandsClaimed() const { return claimed_; }

  bool Empty() const { return observers_.count == 0; }

  void Deliver(NSDictionary *tx) {
    [pending_ addObject:tx];
    if (delivering_) return;
    delivering_ = true;
    while (pending_.count) {
      NSDictionary *next = pending_.firstObject;
      [pending_ removeObjectAtIndex:0];
      NSArray<NSNumber *> *tokens = [observers_.allKeys sortedArrayUsingSelector:@selector(compare:)];
      for (NSNumber *token in tokens)
        if (Observer observer = observers_[token]) observer(next);
    }
    delivering_ = false;
  }

 private:
  NSMutableDictionary<NSNumber *, Observer> *observers_ = [NSMutableDictionary dictionary];
  NSMutableArray<NSDictionary *> *pending_ = [NSMutableArray array];
  NSInteger last_ = 0;
  NSInteger handler_ = 0;
  bool claimed_ = false;
  bool delivering_ = false;
};

}
