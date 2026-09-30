// Çevrimdışı satış kuyruğu (C-01..C-05). Satışlar kimlikleriyle saklanır; sunucu tekrar gönderimde
// aynı satışı ikinci kez kaydetmez (S-02), bu yüzden gönderim güvenle tekrarlanabilir.
import { idbAll, idbDelete, idbGet, idbPut, STORES } from "./idb";

export interface QueuedSale {
  id: string;
  businessId: string;
  payload: Record<string, unknown>;
  total: number;
  createdAt: string;
  status: "bekliyor" | "sorunlu";
  attempts: number;
  lastError?: string;
}

const EVENT = "alkasu-queue";
const notify = () => typeof window !== "undefined" && window.dispatchEvent(new Event(EVENT));
export const onQueueChange = (fn: () => void) => {
  window.addEventListener(EVENT, fn);
  return () => window.removeEventListener(EVENT, fn);
};

export async function enqueueSale(s: Omit<QueuedSale, "status" | "attempts">): Promise<void> {
  await idbPut(STORES.queue, { ...s, status: "bekliyor", attempts: 0 } satisfies QueuedSale);
  notify();
}
export async function listQueue(): Promise<QueuedSale[]> {
  try {
    return (await idbAll<QueuedSale>(STORES.queue)).sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  } catch {
    return [];
  }
}
export async function countPending(): Promise<number> {
  return (await listQueue()).length;
}
export async function removeQueued(id: string): Promise<void> {
  await idbDelete(STORES.queue, id);
  notify();
}
export async function markProblem(id: string, error: string): Promise<void> {
  const s = await idbGet<QueuedSale>(STORES.queue, id);
  if (!s) return;
  await idbPut(STORES.queue, { ...s, status: "sorunlu", attempts: s.attempts + 1, lastError: error });
  notify();
}
export async function markRetry(id: string): Promise<void> {
  const s = await idbGet<QueuedSale>(STORES.queue, id);
  if (!s) return;
  await idbPut(STORES.queue, { ...s, status: "bekliyor", lastError: undefined });
  notify();
}

// Katalog önbelleği (çevrimdışı satış ekranı için)
export async function saveCache<T>(key: string, value: T): Promise<void> {
  try {
    await idbPut(STORES.cache, { at: new Date().toISOString(), value }, key);
  } catch {
    /* önbellek isteğe bağlı */
  }
}
export async function loadCache<T>(key: string): Promise<{ at: string; value: T } | undefined> {
  try {
    return await idbGet<{ at: string; value: T }>(STORES.cache, key);
  } catch {
    return undefined;
  }
}
