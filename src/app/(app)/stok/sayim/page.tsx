import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime } from "@/lib/format";
import { loadLiteProducts } from "@/lib/products-lite";
import { StartCount } from "@/components/stock/start-count";
import { COUNT_STATUS, type CountStatus } from "@/lib/stock-count";

export const metadata = { title: "Sayım" };

export default async function CountsPage() {
  const ctx = await requirePermission("count");
  const supabase = await supabaseServer();
  const [{ data }, products] = await Promise.all([
    supabase.from("stock_counts").select("id, no, scope, status, started_at, decided_at, note").eq("business_id", ctx.businessId).order("started_at", { ascending: false }).limit(50),
    loadLiteProducts(supabase, ctx.businessId),
  ]);
  const rows = (data ?? []) as { id: string; no: number; scope: string; status: string; started_at: string; decided_at: string | null; note: string | null }[];
  const open = rows.find((r) => r.status === "acik" || r.status === "onayda");
  return (
    <div className="space-y-4">
      <PageHeader title="Sayım" subtitle="Sayan kişi onaya gönderir; farklar iki yönetici onayından sonra stoğa yansır" />
      {open ? (
        <Link href={`/stok/sayim/${open.id}`} className="block rounded-2xl bg-brand p-4 text-center font-semibold text-white">
          Sayım #{open.no} · {open.status === "onayda" ? (ctx.role === "yonetici" ? "fark raporu ve onay" : "yönetim onayında") : "devam et"}
          <span className="block text-sm font-normal opacity-90">Stoğa henüz işlenmedi; iki yönetici onayından sonra işlenir.</span>
        </Link>
      ) : (
        <StartCount products={products} />
      )}
      <DataTable rows={rows} rowKey={(r) => r.id} onRowClick={(r) => `/stok/sayim/${r.id}`} mobileTitle={(r) => `Sayım #${r.no}`}
        columns={[
          { key: "no", label: "No", hideOnMobile: true, render: (r) => `#${r.no}` },
          { key: "t", label: "Başlangıç", render: (r) => formatDateTime(r.started_at) },
          { key: "s", label: "Kapsam", render: (r) => (r.scope === "tam" ? "Tam sayım" : "Kısmi") },
          { key: "d", label: "Durum", render: (r) => { const st = COUNT_STATUS[r.status as CountStatus] ?? COUNT_STATUS.acik; return <Badge tone={st.tone}>{st.label}</Badge>; } },
          { key: "k", label: "Onay", hideOnMobile: true, render: (r) => (r.decided_at ? formatDateTime(r.decided_at) : "—") },
        ]} />
    </div>
  );
}
