import type { SupabaseClient } from "@supabase/supabase-js";
import type { CatalogUnit } from "@/lib/catalog";
import type { PriceList } from "@/lib/roles";
import { loadUnitLayout, shopInfo, type ProductShopInfo } from "@/lib/staff-catalog";

export type OrderStatus = "onay_bekliyor" | "acik" | "teslim_edildi" | "iptal";
export const ORDER_STATUS: Record<OrderStatus, string> = { onay_bekliyor: "Onay bekliyor", acik: "Açık", teslim_edildi: "Teslim edildi", iptal: "İptal" };

export interface OrderProduct extends ProductShopInfo {
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
  ownerDealerId: string | null;
  /** Firmaya özel fiyatlar: birim → fiyat (F-13) */
  specialPrices: Record<string, number>;
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
  image_path: string | null;
  brands: { name: string; show_in_shop: boolean | null } | null;
  categories: { name: string } | null;
  product_units: { id: string; name: string; factor: number; price: string | number | null; is_base: boolean; active: boolean; sort: number }[];
}

/** Sipariş formu için ürünler (fiyat listeleriyle). Satış ekranından hafiftir; stok raporu gerektirmez (bayi de kullanır). */
export async function loadOrderProducts(supabase: SupabaseClient, businessId: string): Promise<OrderProduct[]> {
  const [prod, lp, layout] = await Promise.all([
    supabase
      .from("products")
      .select("id, code, name, deposit_amount, image_path, brands(name, show_in_shop), categories(name), product_units(id, name, factor, price, is_base, active, sort)")
      .eq("business_id", businessId)
      .eq("active", true)
      .eq("is_container", false)
      .order("name"),
    supabase.from("product_list_prices").select("unit_id, price_list, price").eq("business_id", businessId),
    loadUnitLayout(supabase, businessId),
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
      ...shopInfo(p),
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
          layout: layout[u.id],
        })),
    }))
    .filter((p) => p.units.some((u) => u.price !== null || Object.keys(u.listPrices).length > 0));
}

export async function loadOrderCustomers(supabase: SupabaseClient, businessId: string): Promise<OrderCustomer[]> {
  const [{ data, error }, cp] = await Promise.all([
    supabase
      .from("customers")
      .select("id, code, name, address, price_list, default_assignee, owner_dealer_id")
      .eq("business_id", businessId)
      .eq("active", true)
      .order("name"),
    supabase.from("customer_prices").select("customer_id, unit_id, price").eq("business_id", businessId),
  ]);
  if (error) throw error;
  const special = new Map<string, Record<string, number>>();
  for (const r of (cp.data ?? []) as { customer_id: string; unit_id: string; price: string | number }[]) {
    special.set(r.customer_id, { ...(special.get(r.customer_id) ?? {}), [r.unit_id]: Number(r.price) });
  }
  return ((data ?? []) as { id: string; code: string; name: string; address: string | null; price_list: PriceList | null; default_assignee: string | null; owner_dealer_id: string | null }[]).map(
    (c) => ({
      id: c.id, code: c.code, name: c.name, address: c.address, priceList: c.price_list ?? "perakende",
      defaultAssignee: c.default_assignee, ownerDealerId: c.owner_dealer_id, specialPrices: special.get(c.id) ?? {},
    }),
  );
}

export async function loadAssignees(supabase: SupabaseClient, businessId: string): Promise<Assignee[]> {
  const { data } = await supabase.rpc("assignable_users", { p_business: businessId });
  return (data ?? []) as Assignee[];
}

export interface Dealer {
  id: string;
  name: string;
}

export async function loadDealers(supabase: SupabaseClient, businessId: string): Promise<Dealer[]> {
  const { data } = await supabase.from("customers").select("id, name").eq("business_id", businessId).eq("channel", "bayi").eq("active", true).order("name");
  return (data ?? []) as Dealer[];
}

/** Bayi listesi (bayi başka bayinin kartını göremediği için RPC ile; yalnızca ad) */
export async function loadDealerNames(supabase: SupabaseClient, businessId: string): Promise<Dealer[]> {
  const { data } = await supabase.rpc("dealer_list", { p_business: businessId });
  return (data ?? []) as Dealer[];
}

/** Bayi için sipariş formu ayarı: kendisi + kendi müşterileri, teslim eden seçenekleri */
export function dealerOrderSetup(customers: OrderCustomer[], dealers: Dealer[], myCustomerId: string | null) {
  const me = customers.find((c) => c.id === myCustomerId) ?? null;
  if (!me) return null;
  return {
    customers: [me, ...customers.filter((c) => c.ownerDealerId === me.id)],
    dealerMode: { me, dealers },
  };
}
