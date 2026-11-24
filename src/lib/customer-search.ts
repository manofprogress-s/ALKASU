// Müşteri araması (M-28, M-29). Asıl arama sunucuda: public.search_customers (aynı kurallar; bayi kartları üstte).
// Buradaki eşdeğer kurallar yalnızca bayinin kendi küçük müşteri listesinde (tarayıcıda) kullanılır.
import { searchKey } from "./catalog";
import type { PriceList } from "./roles";
import type { OrderCustomer } from "./orders";
import type { PosCustomer } from "./catalog";

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

export interface DealerHint { id: string; code: string; name: string }

/** public.search_customers satırı */
export interface CustomerSearchRow {
  id: string; code: string; name: string; address: string | null; phone: string | null; channel: string;
  price_list: PriceList | null; default_assignee: string | null; owner_dealer_id: string | null;
  credit_limit: number | string; unlimited_credit: boolean; balance: number | string;
  special_prices: Record<string, number | string> | null; deposits: Record<string, number | string> | null;
  containers: { product_id: string; qty: number; amount: number | string; free?: number }[] | null;
  dealer_hint: DealerHint | null; match_rank: number; total: number;
}

const nums = (o: Record<string, number | string> | null | undefined): Record<string, number> => {
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(o ?? {})) out[k] = Number(v);
  return out;
};

export type OrderCustomerHit = OrderCustomer & { matchRank: number; channel: string; dealerHint: DealerHint | null };

export function rowToOrderCustomer(r: CustomerSearchRow): OrderCustomerHit {
  return {
    id: r.id, code: r.code, name: r.name, address: r.address, priceList: r.price_list ?? "perakende",
    defaultAssignee: r.default_assignee, ownerDealerId: r.owner_dealer_id, specialPrices: nums(r.special_prices),
    matchRank: r.match_rank, channel: r.channel, dealerHint: r.dealer_hint,
  };
}

/** Arama sonucundaki bayi ipucu (yerel listedeki müşteride yoktur) */
export function dealerHintOf(c: object): DealerHint | null {
  return "dealerHint" in c ? ((c as { dealerHint?: DealerHint | null }).dealerHint ?? null) : null;
}

export function rowToPosCustomer(r: CustomerSearchRow): PosCustomer {
  return {
    id: r.id, code: r.code, name: r.name, phone: r.phone, creditLimit: Number(r.credit_limit), unlimited: r.unlimited_credit,
    balance: Number(r.balance), priceList: r.price_list ?? "perakende", specialPrices: nums(r.special_prices),
    deposits: nums(r.deposits), channel: r.channel, dealerHint: r.dealer_hint,
  };
}

/** Seçilen müşterinin kap bakiyeleri (satış ekranının depozito hesabı için) */
export function rowContainers(r: CustomerSearchRow): { customerId: string; productId: string; qty: number; amount: number; free: number }[] {
  return (r.containers ?? []).map((c) => ({ customerId: r.id, productId: c.product_id, qty: Number(c.qty), amount: Number(c.amount), free: Number(c.free ?? 0) }));
}

/** Çevrimdışı yedek: son seçilen müşterilerde arama (bayi kartları üstte) */
export function rankLocal<T extends { name: string; code: string; phone?: string | null; channel?: string }>(list: T[], query: string, limit = 10): T[] {
  const d = query.replace(/\D/g, "").replace(/^(90|0)/, "");
  const ranked = list
    .map((c) => ({ c, r: matchRank(c.name, c.code, query) ?? (d.length >= 4 && (c.phone ?? "").replace(/\D/g, "").includes(d) ? 3 : null) }))
    .filter((x): x is { c: T; r: number } => x.r !== null);
  return ranked
    .sort((a, b) => Number(b.c.channel === "bayi") - Number(a.c.channel === "bayi") || a.r - b.r || a.c.name.localeCompare(b.c.name, "tr"))
    .slice(0, limit)
    .map((x) => x.c);
}
