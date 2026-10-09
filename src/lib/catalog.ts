import type { SupabaseClient } from "@supabase/supabase-js";
import type { PriceList } from "@/lib/roles";

export interface CatalogUnit {
  id: string;
  name: string;
  factor: number;
  price: number | null;
  /** Bayi / palet liste fiyatları (F-10). Yoksa perakende fiyat geçerlidir. */
  listPrices: Partial<Record<Exclude<PriceList, "perakende">, number>>;
  isBase: boolean;
}

/** Fiyat önceliği (F-13, app.customer_unit_price ile aynı kural): firmaya özel fiyat > fiyat listesi > perakende. */
export function priceFor(u: CatalogUnit, list: PriceList | null | undefined, special?: Record<string, number> | null): number | null {
  return special?.[u.id] ?? unitPrice(u, list);
}

/** Müşterinin fiyat listesine göre birim fiyatı (veritabanındaki app.unit_list_price ile aynı kural). */
export function unitPrice(u: CatalogUnit, list: PriceList | null | undefined): number | null {
  if (!list || list === "perakende") return u.price;
  return u.listPrices?.[list] ?? u.price;
}
export interface CatalogProduct {
  id: string;
  code: string;
  name: string;
  brand: string | null;
  baseUnit: string;
  deposit: number | null;
  emptyProductId: string | null;
  stock: number;
  sold: number;
  units: CatalogUnit[];
  barcodes: { barcode: string; unitId: string | null }[];
}
export interface PosCustomer {
  id: string;
  code: string;
  name: string;
  phone: string | null;
  creditLimit: number;
  unlimited: boolean;
  balance: number;
  priceList: PriceList;
  /** Firmaya özel fiyatlar: birim → fiyat */
  specialPrices?: Record<string, number>;
}
export interface PosData {
  products: CatalogProduct[];
  customers: PosCustomer[];
  containers: { customerId: string | null; productId: string; qty: number; amount: number }[];
  loadedAt: string;
}

interface ProductRow {
  id: string;
  code: string;
  name: string;
  base_unit_name: string;
  deposit_amount: string | number | null;
  empty_product_id: string | null;
  brands: { name: string } | null;
  product_units: { id: string; name: string; factor: number; price: string | number | null; is_base: boolean; active: boolean; sort: number }[];
  product_barcodes: { barcode: string; unit_id: string | null }[];
}

/** Satış ekranı verisi. Hem sunucuda hem istemcide (yenileme) kullanılır. */
export async function loadPosData(supabase: SupabaseClient, businessId: string): Promise<PosData> {
  const [prod, stock, cust, bal, cont, lp, cp] = await Promise.all([
    supabase
      .from("products")
      .select(
        "id, code, name, base_unit_name, deposit_amount, empty_product_id, brands(name), product_units(id, name, factor, price, is_base, active, sort), product_barcodes(barcode, unit_id)",
      )
      .eq("business_id", businessId)
      .eq("active", true)
      .eq("is_container", false)
      .order("name"),
    supabase.rpc("report_stock", { p_business: businessId, p_days: 30 }),
    supabase.from("customers").select("id, code, name, phone, credit_limit, unlimited_credit, price_list").eq("business_id", businessId).eq("active", true).order("name"),
    supabase.from("customer_balances").select("customer_id, balance").eq("business_id", businessId),
    supabase.from("container_balances").select("customer_id, product_id, qty, amount").eq("business_id", businessId),
    supabase.from("product_list_prices").select("unit_id, price_list, price").eq("business_id", businessId),
    supabase.from("customer_prices").select("customer_id, unit_id, price").eq("business_id", businessId),
  ]);
  if (prod.error) throw prod.error;
  const stockMap = new Map<string, { qty: number; sold: number }>();
  for (const s of (stock.data ?? []) as { product_id: string; qty: number; sold_qty: number }[]) {
    stockMap.set(s.product_id, { qty: s.qty, sold: Number(s.sold_qty) });
  }
  const listMap = new Map<string, CatalogUnit["listPrices"]>();
  for (const r of (lp.data ?? []) as { unit_id: string; price_list: "bayi" | "palet"; price: string | number }[]) {
    listMap.set(r.unit_id, { ...(listMap.get(r.unit_id) ?? {}), [r.price_list]: Number(r.price) });
  }
  const special = new Map<string, Record<string, number>>();
  for (const r of (cp.data ?? []) as { customer_id: string; unit_id: string; price: string | number }[]) {
    special.set(r.customer_id, { ...(special.get(r.customer_id) ?? {}), [r.unit_id]: Number(r.price) });
  }
  const balMap = new Map<string, number>();
  for (const b of (bal.data ?? []) as { customer_id: string; balance: string | number }[]) balMap.set(b.customer_id, Number(b.balance));

  const products = ((prod.data ?? []) as unknown as ProductRow[])
    .map((p) => {
      const units = p.product_units
        .filter((u) => u.active)
        .sort((a, b) => Number(b.is_base) - Number(a.is_base) || a.sort - b.sort)
        .map((u) => ({ id: u.id, name: u.name, factor: u.factor, price: u.price === null ? null : Number(u.price), listPrices: listMap.get(u.id) ?? {}, isBase: u.is_base }));
      return {
        id: p.id,
        code: p.code,
        name: p.name,
        brand: p.brands?.name ?? null,
        baseUnit: p.base_unit_name,
        deposit: p.deposit_amount === null ? null : Number(p.deposit_amount),
        emptyProductId: p.empty_product_id,
        stock: stockMap.get(p.id)?.qty ?? 0,
        sold: stockMap.get(p.id)?.sold ?? 0,
        units,
        barcodes: p.product_barcodes.map((b) => ({ barcode: b.barcode, unitId: b.unit_id })),
      } satisfies CatalogProduct;
    })
    .filter((p) => p.units.some((u) => u.price !== null));

  return {
    products,
    customers: ((cust.data ?? []) as { id: string; code: string; name: string; phone: string | null; credit_limit: string | number; unlimited_credit: boolean; price_list: PriceList | null }[]).map(
      (c) => ({
        id: c.id,
        code: c.code,
        name: c.name,
        phone: c.phone,
        creditLimit: Number(c.credit_limit),
        unlimited: c.unlimited_credit,
        balance: balMap.get(c.id) ?? 0,
        priceList: c.price_list ?? "perakende",
        specialPrices: special.get(c.id) ?? {},
      }),
    ),
    containers: ((cont.data ?? []) as { customer_id: string | null; product_id: string; qty: number; amount: string | number }[]).map((c) => ({
      customerId: c.customer_id,
      productId: c.product_id,
      qty: c.qty,
      amount: Number(c.amount),
    })),
    loadedAt: new Date().toISOString(),
  };
}

/** Türkçe duyarlı arama anahtarı */
export function searchKey(s: string): string {
  return s.toLocaleLowerCase("tr-TR").normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/ı/g, "i");
}
