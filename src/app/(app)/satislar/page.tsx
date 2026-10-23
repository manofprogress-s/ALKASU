import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, Card, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { addDaysISO, formatDateTime, formatTRY, todayISO } from "@/lib/format";
import { DateFilter } from "@/components/ui/date-filter";
import { SEGMENTS, segmentOf, segmentTotals, type Segment } from "@/lib/sales-segments";
import { Chip, ChipBar } from "@/components/ui/chips";

export const metadata = { title: "Satışlar" };

interface Row {
  id: string;
  no: number;
  sold_at: string;
  status: string;
  grand_total: number;
  offline: boolean;
  late_sync: boolean;
  customers: { name: string; channel: string } | null;
  sale_payments: { method: string; amount: number }[];
  sale_items: { qty: number; unit_name: string; products: { name: string } | null }[];
}

export default async function SalesPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string; talep?: string; tur?: string }> }) {
  const ctx = await requirePermission("viewSales");
  const sp = await searchParams;
  const to = sp.to ?? todayISO();
  const from = sp.from ?? to;
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("sales")
    .select("id, no, sold_at, status, grand_total, offline, late_sync, customers(name, channel), sale_payments(method, amount), sale_items(qty, unit_name, products(name))")
    .eq("business_id", ctx.businessId)
    .gte("sold_at", `${from}T00:00:00+03:00`)
    .lt("sold_at", `${addDaysISO(to, 1)}T00:00:00+03:00`)
    .order("sold_at", { ascending: false })
    .limit(500);
  const all = (data ?? []) as unknown as Row[];
  const seg: Segment | null = SEGMENTS.some((x) => x.key === sp.tur) ? (sp.tur as Segment) : null;
  const totals = segmentTotals(all.map((r) => ({ ...r, channel: r.customers?.channel ?? null })));
  const rows = seg ? all.filter((r) => segmentOf(r.customers?.channel) === seg) : all;
  const own = ctx.role !== "yonetici";
  const tab = (t: Segment | null) => {
    const q = new URLSearchParams({ from, to });
    if (t) q.set("tur", t);
    return `/satislar?${q.toString()}`;
  };
  const { data: requests } = await supabase
    .from("return_requests")
    .select("id, sale_id, reason, requested_at, sales(no)")
    .eq("business_id", ctx.businessId)
    .eq("status", "bekliyor")
    .order("requested_at");

  return (
    <div>
      <PageHeader
        title="Satışlar"
        subtitle={own ? "Yalnızca sizin kaydettiğiniz satışlar (teslim ettiğiniz siparişler dahil)" : "İşletmenin tüm satışları"}
        actions={<Link href="/satislar/bekleyen" className="text-sm text-brand">Gönderilmeyenler →</Link>}
      />
      <DateFilter from={from} to={to} />
      <div className="mb-3 grid grid-cols-2 gap-2 md:grid-cols-4">
        <Stat label="Kurumsal" value={formatTRY(totals.kurumsal.total)} hint={`${totals.kurumsal.count} fiş`} />
        <Stat label="Perakende" value={formatTRY(totals.perakende.total)} hint={`${totals.perakende.count} fiş`} />
        {totals.bayi.count ? <Stat label="Bayi" value={formatTRY(totals.bayi.total)} hint={`${totals.bayi.count} fiş`} /> : null}
        <Stat label="Genel toplam" value={formatTRY(totals.all.total)} hint={`${totals.all.count} fiş · iptaller hariç`} tone="ok" />
      </div>
      <ChipBar wrap label="Satış türü" className="mb-3">
        {[null, ...SEGMENTS.map((x) => x.key)].filter((k) => k !== "bayi" || totals.bayi.count || seg === "bayi").map((k) => (
          <Chip key={k ?? "tumu"} href={tab(k)} active={seg === k}>{k ? SEGMENTS.find((x) => x.key === k)!.label : "Tümü"}</Chip>
        ))}
      </ChipBar>
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
      {(seg ? [seg] : SEGMENTS.map((x) => x.key)).map((k) => {
        const list = rows.filter((r) => segmentOf(r.customers?.channel) === k);
        if (!seg && !list.length) return null;
        const t = totals[k];
        return (
          <section key={k} className="mb-5 space-y-2">
            <Card className="flex flex-wrap items-center justify-between gap-2 py-2">
              <span className="font-semibold">{SEGMENTS.find((x) => x.key === k)!.label} satışlar</span>
              <span className="num text-sm">{t.count} fiş · <b>{formatTRY(t.total)}</b></span>
            </Card>
            <DataTable
              rows={list}
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
                { key: "i", label: "Kalemler", className: "max-w-xs text-xs text-muted",
                  render: (r) => r.sale_items.map((i) => `${i.qty} ${i.unit_name} ${i.products?.name ?? ""}`).join(", ") || "—" },
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
          </section>
        );
      })}
      {!seg && !rows.length ? <div className="rounded-2xl border border-dashed border-border p-8 text-center text-muted">Bu tarih aralığında satış yok</div> : null}
      {all.length >= 500 ? <p className="text-xs text-warn">İlk 500 fiş gösteriliyor; tarih aralığını daraltın.</p> : null}
    </div>
  );
}
