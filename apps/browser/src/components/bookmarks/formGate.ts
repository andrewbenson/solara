export function formGate() {
  let saving = false;
  return async (saves: boolean, run: () => Promise<void> | void) => {
    if (saving) return;
    if (!saves) return run();
    saving = true;
    try {
      await run();
    } finally {
      saving = false;
    }
  };
}
