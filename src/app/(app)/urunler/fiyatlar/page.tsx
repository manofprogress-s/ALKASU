import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { PriceGrid, type PriceRow } from "@/components/products/price-grid";

export const metadata = { title: "Fiyat listeleri" };

interface UnitRow {
  id: string;
  name: string;
  factor: number;
  price: string | number | null;
  active: boolean;
  is_base: boolean;
}

export default async function PriceListsPage() {
  const ctx = await requirePermission("productEdit");
  const supabase = await supabaseServer();
  const [{ data: prods }, { data: lp }] = await Promise.all([
    supabase
      .from("products")
      .select("id, code, name, is_container, product_units(id, name, factor, price, active, is_base)")
      .eq("business_id", ctx.businessId)
      .eq("active", true)
      .eq("is_container", false)
      .order("name"),
    supabase.from("product_list_prices").select("unit_id, price_list, price").eq("business_id", ctx.businessId),
  ]);
  const lists = new Map<string, { bayi?: number; palet?: number }>();
  for (const r of (lp ?? []) as { unit_id: string; price_list: "bayi" | "palet"; price: string | number }[]) {
    lists.set(r.unit_id, { ...(lists.get(r.unit_id) ?? {}), [r.price_list]: Number(r.price) });
  }
  const rows: PriceRow[] = [];
  for (const p of (prods ?? []) as { id: string; code: string; name: string; product_units: UnitRow[] }[]) {
    const units = p.product_units.filter((u) => u.active).sort((a, b) => b.factor - a.factor);
    // Fiyatı olan birimler; hiçbirinde fiyat yoksa en büyük birim gösterilir
    const priced = units.filter((u) => u.price !== null || lists.has(u.id));
    for (const u of priced.length ? priced : units.slice(0, 1)) {
      const l = lists.get(u.id) ?? {};
      rows.push({
        unitId: u.id,
        code: p.code,
        product: p.name,
        unit: u.name,
        factor: u.factor,
        perakende: u.price === null ? null : Number(u.price),
        bayi: l.bayi ?? null,
        palet: l.palet ?? null,
      });
    }
  }
  return (
    <div className="space-y-4">
      <PageHeader
        title="Fiyat listeleri"
        subtitle="Perakende, bayi ve palet fiyatları (KDV dahil, birim başına). Bayi/palet fiyatı boşsa perakende fiyat uygulanır."
      />
      <PriceGrid rows={rows} />
    </div>
  );
}
