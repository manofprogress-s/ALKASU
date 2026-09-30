import type { SupabaseClient } from "@supabase/supabase-js";

export interface LiteProduct {
  id: string;
  code: string;
  name: string;
  baseUnit: string;
  isContainer: boolean;
  units: { id: string; name: string; factor: number }[];
}

export async function loadLiteProducts(supabase: SupabaseClient, businessId: string, includeInactive = false): Promise<LiteProduct[]> {
  let q = supabase
    .from("products")
    .select("id, code, name, base_unit_name, is_container, active, product_units(id, name, factor, active, is_base)")
    .eq("business_id", businessId)
    .order("name");
  if (!includeInactive) q = q.eq("active", true);
  const { data } = await q;
  return ((data ?? []) as unknown as {
    id: string; code: string; name: string; base_unit_name: string; is_container: boolean;
    product_units: { id: string; name: string; factor: number; active: boolean; is_base: boolean }[];
  }[]).map((p) => ({
    id: p.id,
    code: p.code,
    name: p.name,
    baseUnit: p.base_unit_name,
    isContainer: p.is_container,
    units: p.product_units.filter((u) => u.active).sort((a, b) => a.factor - b.factor).map((u) => ({ id: u.id, name: u.name, factor: u.factor })),
  }));
}
