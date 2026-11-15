type Admission = (task: () => void, cancelled: () => void) => () => void;

export class AfterFirstWindowQueue {
  private admission: Admission | undefined;
  private waiting = new Map<object, { run: () => void; cancelled: () => void; cancel?: () => void }>();

  install(admission: Admission) {
    this.admission = admission;
    for (const entry of this.waiting.values()) {
      entry.cancel?.();
      entry.cancel = admission(entry.run, entry.cancelled);
    }
  }

  add(task: () => void) {
    const token = {};
    const entry: { run: () => void; cancelled: () => void; cancel?: () => void } = {
      cancelled: () => { this.waiting.delete(token); },
      run: () => {
        if (!this.waiting.delete(token)) return;
        try {
          task();
        } catch (error) {
          console.warn("[launch] deferred work failed", error);
        }
      },
    };
    this.waiting.set(token, entry);
    if (this.admission) entry.cancel = this.admission(entry.run, entry.cancelled);
    return () => {
      if (!this.waiting.delete(token)) return;
      entry.cancel?.();
    };
  }
}

const queue = new AfterFirstWindowQueue();
export const installAfterFirstWindowScheduler = (admission: Admission) => queue.install(admission);
export const afterFirstWindow = (task: () => void) => queue.add(task);
