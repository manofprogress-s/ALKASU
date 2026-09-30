import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime, formatNumber } from "@/lib/format";
import { MOVEMENT_LABELS } from "@/lib/labels";


export default async function StockHistory({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("receiveGoods");
  const { id } = await params;
  const supabase = await supabaseServer();
  const [{ data: p }, { data: lvl }, { data: mv }, { data: members }] = await Promise.all([
    supabase.from("products").select("name, code, base_unit_name").eq("id", id).maybeSingle(),
    supabase.from("stock_levels").select("qty").eq("product_id", id).maybeSingle(),
    supabase.from("stock_movements").select("id, qty, type, note, created_at, created_by").eq("product_id", id).order("id", { ascending: false }).limit(300),
    supabase.from("memberships").select("user_id, display_name").eq("business_id", ctx.businessId),
  ]);
  if (!p) notFound();
  const names = new Map((members ?? []).map((m: { user_id: string; display_name: string }): [string, string] => [m.user_id, m.display_name]));
  const rows = (mv ?? []) as { id: number; qty: number; type: string; note: string | null; created_at: string; created_by: string | null }[];
  return (
    <div className="space-y-4">
      <PageHeader title={p.name} subtitle={`${p.code} · stok hareketleri`} />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Güncel stok" value={`${formatNumber(lvl?.qty ?? 0)} ${p.base_unit_name.toLocaleLowerCase("tr-TR")}`} />
      </div>
      <DataTable
        rows={rows}
        rowKey={(r) => String(r.id)}
        mobileTitle={(r) => MOVEMENT_LABELS[r.type] ?? r.type}
        columns={[
          { key: "t", label: "Zaman", render: (r) => formatDateTime(r.created_at) },
          { key: "type", label: "Hareket", hideOnMobile: true, render: (r) => MOVEMENT_LABELS[r.type] ?? r.type },
          { key: "q", label: "Miktar", align: "right", render: (r) => <span className={r.qty < 0 ? "text-danger" : "text-ok"}>{r.qty > 0 ? "+" : ""}{formatNumber(r.qty)}</span> },
          { key: "u", label: "Kullanıcı", render: (r) => (r.created_by ? names.get(r.created_by) ?? "—" : "—") },
          { key: "n", label: "Not", render: (r) => r.note ?? "" },
        ]}
      />
    </div>
  );
}
