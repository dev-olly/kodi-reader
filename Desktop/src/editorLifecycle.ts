type Flush = () => Promise<void>;
const editors = new Set<Flush>();
export function registerEditor(flush: Flush): () => void {
  editors.add(flush);
  return () => { editors.delete(flush); };
}
export async function flushEditors(): Promise<void> {
  // Finish saves before switching native reader sessions or destroying a window.
  // A failed save deliberately keeps the editor available for retry.
  for (const flush of [...editors]) await flush();
}

export function createDraftFlusher(
  pending: () => string,
  saved: () => string,
  save: (text: string) => Promise<boolean>,
  hasPendingMetadata: () => boolean = () => false,
): () => Promise<boolean> {
  let inFlight: Promise<boolean> | null = null;
  return () => {
    if (inFlight) return inFlight;
    inFlight = (async () => {
      while (pending() !== saved() || hasPendingMetadata()) {
        // Re-read after every write: typing can continue while a save waits
        // behind another native mutation, or while a recording is encoded.
        if (!await save(pending())) return false;
      }
      return true;
    })().finally(() => { inFlight = null; });
    return inFlight;
  };
}
