// Küçük IndexedDB yardımcı katmanı (bağımlılıksız).
const DB_NAME = "alkasu";
const DB_VERSION = 1;
export const STORES = { queue: "sale_queue", cache: "cache" } as const;

let dbPromise: Promise<IDBDatabase> | null = null;

function open(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") return Promise.reject(new Error("IndexedDB desteklenmiyor"));
  dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORES.queue)) db.createObjectStore(STORES.queue, { keyPath: "id" });
      if (!db.objectStoreNames.contains(STORES.cache)) db.createObjectStore(STORES.cache);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

function wrap<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function idbGet<T>(store: string, key: IDBValidKey): Promise<T | undefined> {
  const db = await open();
  return wrap(db.transaction(store).objectStore(store).get(key)) as Promise<T | undefined>;
}
export async function idbPut(store: string, value: unknown, key?: IDBValidKey): Promise<void> {
  const db = await open();
  await wrap(db.transaction(store, "readwrite").objectStore(store).put(value, key));
}
export async function idbDelete(store: string, key: IDBValidKey): Promise<void> {
  const db = await open();
  await wrap(db.transaction(store, "readwrite").objectStore(store).delete(key));
}
export async function idbAll<T>(store: string): Promise<T[]> {
  const db = await open();
  return wrap(db.transaction(store).objectStore(store).getAll()) as Promise<T[]>;
}
