import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime } from "@/lib/format";
import { loadLiteProducts } from "@/lib/products-lite";
import { StartCount } from "@/components/stock/start-count";

export const metadata = { title: "Sayım" };

export default async function CountsPage() {
  const ctx = await requirePermission("count");
  const supabase = await supabaseServer();
  const [{ data }, products] = await Promise.all([
    supabase.from("stock_counts").select("id, no, scope, status, started_at, decided_at, note").eq("business_id", ctx.businessId).order("started_at", { ascending: false }).limit(50),
    loadLiteProducts(supabase, ctx.businessId),
  ]);
  const rows = (data ?? []) as { id: string; no: number; scope: string; status: string; started_at: string; decided_at: string | null; note: string | null }[];
  const open = rows.find((r) => r.status === "acik");
  return (
    <div className="space-y-4">
      <PageHeader title="Sayım" subtitle="Sayım farkları yönetici onayıyla stoğa yansır" />
      {open ? (
        <Link href={`/stok/sayim/${open.id}`} className="block rounded-2xl bg-brand p-4 text-center font-semibold text-white">Açık sayıma devam et (#{open.no})</Link>
      ) : (
        <StartCount products={products} />
      )}
      <DataTable rows={rows} rowKey={(r) => r.id} onRowClick={(r) => `/stok/sayim/${r.id}`} mobileTitle={(r) => `Sayım #${r.no}`}
        columns={[
          { key: "no", label: "No", hideOnMobile: true, render: (r) => `#${r.no}` },
          { key: "t", label: "Başlangıç", render: (r) => formatDateTime(r.started_at) },
          { key: "s", label: "Kapsam", render: (r) => (r.scope === "tam" ? "Tam sayım" : "Kısmi") },
          { key: "d", label: "Durum", render: (r) => <Badge tone={r.status === "acik" ? "brand" : r.status === "onaylandi" ? "ok" : "neutral"}>{r.status === "acik" ? "Açık" : r.status === "onaylandi" ? "Onaylandı" : "İptal"}</Badge> },
        ]} />
    </div>
  );
}
