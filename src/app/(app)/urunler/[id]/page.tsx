import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Card, PageHeader } from "@/components/ui/card";
import { ProductForm, type ProductFormValue } from "@/components/products/product-form";
import { formatDateTime, formatTRY } from "@/lib/format";

export default async function ProductEditPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("productEdit");
  const { id } = await params;
  const isNew = id === "yeni";
  const supabase = await supabaseServer();
  const [brands, cats, containers] = await Promise.all([
    supabase.from("brands").select("id, name").eq("business_id", ctx.businessId).eq("active", true).order("name"),
    supabase.from("categories").select("id, name").eq("business_id", ctx.businessId).eq("active", true).order("name"),
    supabase.from("products").select("id, name").eq("business_id", ctx.businessId).eq("is_container", true).eq("active", true).order("name"),
  ]);

  let value: ProductFormValue | null = null;
  let history: { at: string; text: string }[] = [];
  let avgCost: number | null = null;
  if (!isNew) {
    const { data } = await supabase
      .from("products")
      .select("*, product_units(id, name, factor, price, active, is_base, sort), product_barcodes(barcode, unit_id)")
      .eq("id", id)
      .maybeSingle();
    if (!data) notFound();
    const units = (data.product_units as { id: string; name: string; factor: number; price: number | null; active: boolean; is_base: boolean; sort: number }[]);
    const base = units.find((u) => u.is_base);
    value = {
      id: data.id, code: data.code, name: data.name, brand_id: data.brand_id, category_id: data.category_id,
      base_unit_name: data.base_unit_name, base_price: base?.price ?? null, vat_rate: data.vat_rate,
      critical_level: data.critical_level, kind: data.is_container ? "bos_kap" : data.deposit_amount ? "depozitolu" : "normal",
      deposit_amount: data.deposit_amount, empty_product_id: data.empty_product_id, active: data.active,
      units: units.filter((u) => !u.is_base && u.active).sort((a, b) => a.factor - b.factor).map((u) => ({ id: u.id, name: u.name, factor: u.factor, price: u.price })),
      barcodes: (data.product_barcodes as { barcode: string; unit_id: string | null }[]).map((b) => ({
        barcode: b.barcode, unit_name: units.find((u) => u.id === b.unit_id)?.name ?? null,
      })),
    };
    const [{ data: cost }, { data: ch }, { data: ph }] = await Promise.all([
      supabase.from("product_costs").select("avg_cost, has_cost").eq("product_id", id).maybeSingle(),
      supabase.from("cost_history").select("old_cost, new_cost, source, created_at").eq("product_id", id).order("created_at", { ascending: false }).limit(20),
      supabase.from("product_prices").select("price, price_list, valid_from, product_units!inner(name, product_id)").eq("product_units.product_id", id).order("valid_from", { ascending: false }).limit(20),
    ]);
    avgCost = cost?.has_cost ? Number(cost.avg_cost) : null;
    history = [
      ...((ch ?? []) as { old_cost: number | null; new_cost: number; source: string; created_at: string }[]).map((c) => ({
        at: c.created_at, text: `Maliyet ${c.old_cost === null ? "" : `${formatTRY(c.old_cost)} → `}${formatTRY(c.new_cost)} (${c.source === "mal_kabul" ? "mal kabul" : c.source})`,
      })),
      ...((ph ?? []) as unknown as { price: number | null; price_list: string | null; valid_from: string; product_units: { name: string } }[]).map((p) => ({
        at: p.valid_from, text: `${p.product_units.name} ${p.price_list && p.price_list !== "perakende" ? `${p.price_list} fiyatı` : "satış fiyatı"} ${p.price === null ? "kaldırıldı" : formatTRY(p.price)}`,
      })),
    ].sort((a, b) => b.at.localeCompare(a.at));
  }

  return (
    <div className="space-y-4">
      <PageHeader title={isNew ? "Yeni ürün" : value!.name} subtitle={avgCost !== null ? `Ortalama maliyet: ${formatTRY(avgCost)} / ${value!.base_unit_name.toLocaleLowerCase("tr-TR")}` : undefined} />
      <ProductForm
        initial={value}
        brands={(brands.data ?? []) as { id: string; name: string }[]}
        categories={(cats.data ?? []) as { id: string; name: string }[]}
        containers={((containers.data ?? []) as { id: string; name: string }[]).filter((c) => c.id !== value?.id)}
      />
      {history.length > 0 ? (
        <Card>
          <h2 className="mb-2 font-semibold">Fiyat ve maliyet geçmişi</h2>
          <ul className="space-y-1 text-sm">
            {history.map((h, i) => (
              <li key={i} className="flex justify-between gap-3"><span>{h.text}</span><span className="text-muted">{formatDateTime(h.at)}</span></li>
            ))}
          </ul>
        </Card>
      ) : null}
    </div>
  );
}
