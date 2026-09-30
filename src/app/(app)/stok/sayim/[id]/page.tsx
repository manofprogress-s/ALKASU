import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { CountSheet, type CountLine } from "@/components/stock/count-sheet";
import { formatDateTime } from "@/lib/format";

export default async function CountPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("count");
  const { id } = await params;
  const supabase = await supabaseServer();
  const [{ data: c }, { data: lines }] = await Promise.all([
    supabase.from("stock_counts").select("*").eq("id", id).maybeSingle(),
    supabase.from("stock_count_lines").select("product_id, snapshot_qty, counted_qty, moved_during, diff, products(name, code, base_unit_name, product_units(id, name, factor, active))").eq("count_id", id),
  ]);
  if (!c) notFound();
  const rows: CountLine[] = ((lines ?? []) as unknown as {
    product_id: string; snapshot_qty: number; counted_qty: number | null; moved_during: number | null; diff: number | null;
    products: { name: string; code: string; base_unit_name: string; product_units: { id: string; name: string; factor: number; active: boolean }[] };
  }[]).map((l) => ({
    productId: l.product_id, name: l.products.name, code: l.products.code, baseUnit: l.products.base_unit_name,
    units: l.products.product_units.filter((u) => u.active && u.factor > 1).sort((a, b) => b.factor - a.factor),
    snapshot: l.snapshot_qty, counted: l.counted_qty, diff: l.diff,
  })).sort((a, b) => a.name.localeCompare(b.name, "tr"));
  return (
    <div className="space-y-4">
      <PageHeader title={`Sayım #${c.no}`} subtitle={`${c.scope === "tam" ? "Tam sayım" : "Kısmi sayım"} · ${formatDateTime(c.started_at)}${c.note ? ` · ${c.note}` : ""}`} />
      <CountSheet countId={id} status={c.status} lines={rows} canApprove={ctx.role === "yonetici"} />
    </div>
  );
}
