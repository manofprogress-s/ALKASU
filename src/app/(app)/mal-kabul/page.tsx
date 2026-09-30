import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDate, formatDateTime } from "@/lib/format";

export const metadata = { title: "Mal kabul" };

export default async function PurchasesPage() {
  const ctx = await requirePermission("receiveGoods");
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("purchases")
    .select("id, no, doc_no, doc_date, status, created_at, suppliers(name), purchase_items(id)")
    .eq("business_id", ctx.businessId)
    .order("created_at", { ascending: false })
    .limit(200);
  const rows = (data ?? []) as unknown as { id: string; no: number; doc_no: string | null; doc_date: string; status: string; created_at: string; suppliers: { name: string } | null; purchase_items: { id: string }[] }[];
  return (
    <div>
      <PageHeader title="Mal kabul" actions={<Link href="/mal-kabul/yeni" className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni mal kabul</Link>} />
      <DataTable rows={rows} rowKey={(r) => r.id} onRowClick={(r) => `/mal-kabul/${r.id}`} mobileTitle={(r) => `#${r.no} ${r.suppliers?.name ?? ""}`}
        columns={[
          { key: "no", label: "No", hideOnMobile: true, render: (r) => `#${r.no}` },
          { key: "d", label: "Belge tarihi", render: (r) => formatDate(r.doc_date) },
          { key: "s", label: "Tedarikçi", hideOnMobile: true, render: (r) => r.suppliers?.name ?? "—" },
          { key: "doc", label: "İrsaliye", render: (r) => r.doc_no ?? "—" },
          { key: "n", label: "Kalem", align: "right", render: (r) => r.purchase_items.length },
          { key: "st", label: "Durum", render: (r) => r.status === "onaylandi" ? <Badge tone="ok">Onaylandı</Badge> : <Badge tone="warn">Fiyat onayı bekliyor</Badge> },
          { key: "t", label: "Kayıt", hideOnMobile: true, render: (r) => formatDateTime(r.created_at) },
        ]}
        empty="Henüz mal kabul yok" />
    </div>
  );
}
