// Müşteri araması (M-28). Asıl arama sunucuda: public.search_order_customers (aynı kurallar).
// Buradaki eşdeğer kurallar yalnızca bayinin kendi küçük müşteri listesinde (tarayıcıda) kullanılır.
import { searchKey } from "./catalog";
import type { PriceList } from "./roles";
import type { OrderCustomer } from "./orders";

/** Türkçe duyarlı norm: küçük harf, şapkasız, ı/İ → i, harf-rakam dışı → tek boşluk (app.search_norm ile aynı) */
export function searchNorm(s: string | null | undefined): string {
  return searchKey(s ?? "").replace(/[^a-z0-9]+/g, " ").trim();
}

/** Kelimelerin baş harfleri: "turkiye jokey kulubu" → "tjk" */
export function initials(norm: string): string {
  return norm.split(" ").filter(Boolean).map((w) => w[0]).join("");
}

/** 0 tam ad/kod · 1 ad sorguyla başlıyor · 2 kelime başı / baş harfler · 3 içeriyor · null eşleşmiyor */
export function matchRank(name: string, code: string, query: string): number | null {
  const q = searchNorm(query);
  if (!q) return null;
  const qc = q.replace(/ /g, "");
  const n = searchNorm(name);
  const c = code.toLocaleLowerCase("tr-TR");
  const ini = initials(n);
  const words = q.split(" ");
  const hay = ` ${n} ${c}`;
  const hit = words.every((w) => hay.includes(w)) || (qc.length >= 2 && (n.replace(/ /g, "").includes(qc) || ini.startsWith(qc)));
  if (!hit) return null;
  if (n === q || c === q || n.replace(/ /g, "") === qc) return 0;
  if (n.startsWith(q)) return 1;
  if (` ${n}`.includes(` ${q}`) || (qc.length >= 2 && ini.startsWith(qc))) return 2;
  return 3;
}

/** Listeyi sıralı süzer: tam eşleşme üstte, sonra ad sırası */
export function rankCustomers<T extends { name: string; code: string }>(list: T[], query: string, limit = 10): T[] {
  return list
    .map((c) => ({ c, r: matchRank(c.name, c.code, query) }))
    .filter((x): x is { c: T; r: number } => x.r !== null)
    .sort((a, b) => a.r - b.r || a.c.name.localeCompare(b.c.name, "tr"))
    .slice(0, limit)
    .map((x) => x.c);
}

export interface CustomerSearchRow {
  id: string; code: string; name: string; address: string | null; price_list: PriceList | null; default_assignee: string | null;
  owner_dealer_id: string | null; special_prices: Record<string, number | string> | null; match_rank: number; total: number;
}

export function rowToOrderCustomer(r: CustomerSearchRow): OrderCustomer & { matchRank: number } {
  const sp: Record<string, number> = {};
  for (const [k, v] of Object.entries(r.special_prices ?? {})) sp[k] = Number(v);
  return {
    id: r.id, code: r.code, name: r.name, address: r.address, priceList: r.price_list ?? "perakende",
    defaultAssignee: r.default_assignee, ownerDealerId: r.owner_dealer_id, specialPrices: sp, matchRank: r.match_rank,
  };
}
