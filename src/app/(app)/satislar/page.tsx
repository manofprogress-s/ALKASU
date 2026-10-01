import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { addDaysISO, formatDateTime, formatTRY, todayISO } from "@/lib/format";
import { DateFilter } from "@/components/ui/date-filter";

export const metadata = { title: "Satışlar" };

interface Row {
  id: string;
  no: number;
  sold_at: string;
  status: string;
  grand_total: number;
  offline: boolean;
  late_sync: boolean;
  customers: { name: string } | null;
  sale_payments: { method: string; amount: number }[];
}

export default async function SalesPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string; talep?: string }> }) {
  const ctx = await requirePermission("viewSales");
  const sp = await searchParams;
  const to = sp.to ?? todayISO();
  const from = sp.from ?? to;
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("sales")
    .select("id, no, sold_at, status, grand_total, offline, late_sync, customers(name), sale_payments(method, amount)")
    .eq("business_id", ctx.businessId)
    .gte("sold_at", `${from}T00:00:00+03:00`)
    .lt("sold_at", `${addDaysISO(to, 1)}T00:00:00+03:00`)
    .order("sold_at", { ascending: false })
    .limit(500);
  const rows = (data ?? []) as unknown as Row[];
  const { data: requests } = await supabase
    .from("return_requests")
    .select("id, sale_id, reason, requested_at, sales(no)")
    .eq("business_id", ctx.businessId)
    .eq("status", "bekliyor")
    .order("requested_at");
  const total = rows.filter((r) => r.status === "tamamlandi").reduce((s, r) => s + Number(r.grand_total), 0);

  return (
    <div>
      <PageHeader
        title="Satışlar"
        subtitle={`${rows.length} fiş · ${formatTRY(total)}${ctx.role === "satis" || ctx.role === "sevkiyat" ? " · yalnızca sizin satışlarınız" : ""}`}
        actions={<Link href="/satislar/bekleyen" className="text-sm text-brand">Gönderilmeyenler →</Link>}
      />
      <DateFilter from={from} to={to} />
      {(requests ?? []).length > 0 ? (
        <div className="mb-4 rounded-2xl border border-warn/40 bg-warn-soft p-3 text-sm">
          <div className="mb-1 font-semibold text-warn">Bekleyen iade talepleri</div>
          <ul className="space-y-1">
            {(requests as unknown as { id: string; sale_id: string; reason: string; sales: { no: number } | null }[]).map((r) => (
              <li key={r.id}>
                <Link className="text-brand" href={`/satislar/${r.sale_id}?talep=${r.id}`}>
                  Satış #{r.sales?.no}: {r.reason}
                </Link>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
      <DataTable
        rows={rows}
        rowKey={(r) => r.id}
        onRowClick={(r) => `/satislar/${r.id}`}
        mobileTitle={(r) => (
          <span className="flex items-center justify-between">
            <span>#{r.no} {r.customers?.name ?? "Perakende"}</span>
            <span className="num">{formatTRY(r.grand_total)}</span>
          </span>
        )}
        columns={[
          { key: "no", label: "No", render: (r) => `#${r.no}`, hideOnMobile: true },
          { key: "t", label: "Zaman", render: (r) => formatDateTime(r.sold_at) },
          { key: "c", label: "Müşteri", render: (r) => r.customers?.name ?? "Perakende", hideOnMobile: true },
          { key: "p", label: "Ödeme", render: (r) => r.sale_payments.map((p) => (p.method === "nakit" ? "Nakit" : p.method === "pos" ? "POS" : "Veresiye")).join(" + ") || "—" },
          {
            key: "s",
            label: "Durum",
            render: (r) => (
              <span className="inline-flex gap-1">
                {r.status === "iptal" ? <Badge tone="danger">İptal</Badge> : <Badge tone="ok">Tamam</Badge>}
                {r.offline ? <Badge tone="warn">Çevrimdışı</Badge> : null}
              </span>
            ),
          },
          { key: "g", label: "Tutar", align: "right", render: (r) => formatTRY(r.grand_total), hideOnMobile: true },
        ]}
        empty="Bu tarih aralığında satış yok"
      />
    </div>
  );
}
