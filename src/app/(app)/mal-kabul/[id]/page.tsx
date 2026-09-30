import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, Card, PageHeader } from "@/components/ui/card";
import { formatDate, formatTRY } from "@/lib/format";
import { ApproveCosts } from "@/components/purchases/approve-costs";

export default async function PurchaseDetail({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("receiveGoods");
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("purchases")
    .select("*, suppliers(name), purchase_items(id, qty, free_qty, factor, products(name), product_units(name)), purchase_empties(qty, products(name))")
    .eq("id", id)
    .maybeSingle();
  if (!data) notFound();
  const p = data as unknown as {
    id: string; no: number; doc_no: string | null; doc_date: string; status: string; suppliers: { name: string } | null;
    purchase_items: { id: string; qty: number; free_qty: number; factor: number; products: { name: string }; product_units: { name: string } }[];
    purchase_empties: { qty: number; products: { name: string } }[];
  };
  let costs = new Map<string, { unit_cost: number; line_total: number }>();
  if (ctx.role === "yonetici") {
    const { data: c } = await supabase.from("purchase_item_costs").select("purchase_item_id, unit_cost, line_total").in("purchase_item_id", p.purchase_items.map((i) => i.id));
    costs = new Map((c ?? []).map((x: { purchase_item_id: string; unit_cost: number; line_total: number }) => [x.purchase_item_id, x]));
  }
  const total = [...costs.values()].reduce((s, c) => s + Number(c.line_total), 0);
  return (
    <div className="space-y-4">
      <PageHeader title={`Mal kabul #${p.no}`} subtitle={`${p.suppliers?.name ?? "Tedarikçi yok"} · ${formatDate(p.doc_date)}${p.doc_no ? ` · ${p.doc_no}` : ""}`}
        actions={p.status === "onaylandi" ? <Badge tone="ok">Onaylandı</Badge> : <Badge tone="warn">Fiyat onayı bekliyor</Badge>} />
      {p.status === "onay_bekliyor" && ctx.role === "yonetici" ? (
        <ApproveCosts purchaseId={p.id} items={p.purchase_items.map((i) => ({ id: i.id, name: i.products.name, unit: i.product_units.name, qty: i.qty, free: i.free_qty }))} />
      ) : (
        <Card className="divide-y divide-border p-0">
          {p.purchase_items.map((i) => (
            <div key={i.id} className="flex justify-between gap-2 p-3 text-sm">
              <span>{i.products.name} · {i.qty} {i.product_units.name}{i.free_qty ? ` + ${i.free_qty} bedelsiz` : ""}</span>
              {costs.get(i.id) ? <span className="num">{formatTRY(costs.get(i.id)!.unit_cost)} → {formatTRY(costs.get(i.id)!.line_total)}</span> : null}
            </div>
          ))}
          {ctx.role === "yonetici" && costs.size ? <div className="num flex justify-between p-3 font-semibold"><span>Toplam</span><span>{formatTRY(total)}</span></div> : null}
        </Card>
      )}
      {p.purchase_empties.length ? (
        <Card className="text-sm">
          <div className="mb-1 font-semibold">Tedarikçiye verilen boş kaplar</div>
          {p.purchase_empties.map((e, k) => <div key={k}>{e.products.name}: {e.qty}</div>)}
        </Card>
      ) : null}
    </div>
  );
}
