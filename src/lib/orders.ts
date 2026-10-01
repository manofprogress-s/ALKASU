import type { SupabaseClient } from "@supabase/supabase-js";
import type { CatalogUnit } from "@/lib/catalog";
import type { PriceList } from "@/lib/roles";

export type OrderStatus = "acik" | "teslim_edildi" | "iptal";
export const ORDER_STATUS: Record<OrderStatus, string> = { acik: "Açık", teslim_edildi: "Teslim edildi", iptal: "İptal" };

export interface OrderProduct {
  id: string;
  code: string;
  name: string;
  deposit: number | null;
  units: CatalogUnit[];
}

export interface OrderCustomer {
  id: string;
  code: string;
  name: string;
  address: string | null;
  priceList: PriceList;
  defaultAssignee: string | null;
}

export interface Assignee {
  user_id: string;
  display_name: string;
  role: string;
}

interface ProductRow {
  id: string;
  code: string;
  name: string;
  deposit_amount: string | number | null;
  product_units: { id: string; name: string; factor: number; price: string | number | null; is_base: boolean; active: boolean; sort: number }[];
}

/** Sipariş formu için ürünler (fiyat listeleriyle). Satış ekranından hafiftir; stok raporu gerektirmez (bayi de kullanır). */
export async function loadOrderProducts(supabase: SupabaseClient, businessId: string): Promise<OrderProduct[]> {
  const [prod, lp] = await Promise.all([
    supabase
      .from("products")
      .select("id, code, name, deposit_amount, product_units(id, name, factor, price, is_base, active, sort)")
      .eq("business_id", businessId)
      .eq("active", true)
      .eq("is_container", false)
      .order("name"),
    supabase.from("product_list_prices").select("unit_id, price_list, price").eq("business_id", businessId),
  ]);
  if (prod.error) throw prod.error;
  const lists = new Map<string, CatalogUnit["listPrices"]>();
  for (const r of (lp.data ?? []) as { unit_id: string; price_list: "bayi" | "palet"; price: string | number }[]) {
    lists.set(r.unit_id, { ...(lists.get(r.unit_id) ?? {}), [r.price_list]: Number(r.price) });
  }
  return ((prod.data ?? []) as unknown as ProductRow[])
    .map((p) => ({
      id: p.id,
      code: p.code,
      name: p.name,
      deposit: p.deposit_amount === null ? null : Number(p.deposit_amount),
      units: p.product_units
        .filter((u) => u.active)
        .sort((a, b) => b.factor - a.factor || a.sort - b.sort)
        .map((u) => ({
          id: u.id,
          name: u.name,
          factor: u.factor,
          price: u.price === null ? null : Number(u.price),
          listPrices: lists.get(u.id) ?? {},
          isBase: u.is_base,
        })),
    }))
    .filter((p) => p.units.some((u) => u.price !== null || Object.keys(u.listPrices).length > 0));
}

export async function loadOrderCustomers(supabase: SupabaseClient, businessId: string): Promise<OrderCustomer[]> {
  const { data, error } = await supabase
    .from("customers")
    .select("id, code, name, address, price_list, default_assignee")
    .eq("business_id", businessId)
    .eq("active", true)
    .order("name");
  if (error) throw error;
  return ((data ?? []) as { id: string; code: string; name: string; address: string | null; price_list: PriceList | null; default_assignee: string | null }[]).map(
    (c) => ({ id: c.id, code: c.code, name: c.name, address: c.address, priceList: c.price_list ?? "perakende", defaultAssignee: c.default_assignee }),
  );
}

export async function loadAssignees(supabase: SupabaseClient, businessId: string): Promise<Assignee[]> {
  const { data } = await supabase.rpc("assignable_users", { p_business: businessId });
  return (data ?? []) as Assignee[];
}
