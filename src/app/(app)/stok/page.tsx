import Link from "next/link";
import { getContext } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatNumber, formatTRY } from "@/lib/format";
import { can } from "@/lib/roles";
import { SearchBox } from "@/components/ui/search-box";
import { searchKey } from "@/lib/catalog";
import { ExportButton } from "@/components/reports/export-button";

export const metadata = { title: "Stok" };

interface Row {
  product_id: string; code: string; name: string; brand_name: string | null; category_name: string | null; base_unit_name: string; is_container: boolean;
  qty: number; critical_level: number | null; suggested_critical: number | null; sold_qty: number; avg_daily: number; days_of_stock: number | null;
  status: "negatif" | "kritik" | "normal"; speed: "hizli" | "yavas" | "normal" | null; avg_cost: number | null; stock_value: number | null;
}

const SPEED: Record<string, string> = { hizli: "Hızlı", yavas: "Yavaş", normal: "Normal" };

export default async function StockPage({ searchParams }: { searchParams: Promise<{ q?: string; durum?: string; hiz?: string }> }) {
  const ctx = await getContext();
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("report_stock", { p_business: ctx.businessId, p_days: 30 });
  let rows = (data ?? []) as Row[];
  const all = rows;
  if (sp.q) { const k = searchKey(sp.q); rows = rows.filter((r) => searchKey(`${r.name} ${r.code} ${r.brand_name ?? ""}`).includes(k)); }
  if (sp.durum === "uyari") rows = rows.filter((r) => r.status !== "normal" && !r.is_container);
  if (sp.hiz) rows = rows.filter((r) => r.speed === sp.hiz);
  const isAdmin = ctx.role === "yonetici";
  const value = all.reduce((s, r) => s + Number(r.stock_value ?? 0), 0);
  const tab = (href: string, label: string, active: boolean) => (
    <Link href={href} className={`rounded-full px-3 py-1.5 text-sm ${active ? "bg-brand text-white" : "bg-surface-2"}`}>{label}</Link>
  );

  return (
    <div>
      <PageHeader
        title="Stok"
        subtitle="Son 30 günlük satışa göre"
        actions={
          <>
            {can(ctx.role, "waste") ? <Link href="/stok/fire" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Fire / hasar</Link> : null}
            {can(ctx.role, "count") ? <Link href="/stok/sayim" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Sayım</Link> : null}
            <ExportButton filename="stok" rows={rows.map((r) => ({
              Kod: r.code, Ürün: r.name, Marka: r.brand_name ?? "", Birim: r.base_unit_name, Stok: r.qty, "Kritik seviye": r.critical_level ?? "",
              "Önerilen kritik": r.suggested_critical ?? "", "30 gün satış": Number(r.sold_qty), "Günlük ort.": Number(r.avg_daily),
              "Kaç günlük": r.days_of_stock ?? "", Durum: r.status, Hız: r.speed ? SPEED[r.speed] : "",
              ...(isAdmin ? { "Ort. maliyet": Number(r.avg_cost ?? 0), "Stok değeri": Number(r.stock_value ?? 0) } : {}),
            }))} />
          </>
        }
      />
      {error ? <div className="mb-3 text-danger">{error.message}</div> : null}
      <div className="mb-4 grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Kritik" value={all.filter((r) => r.status === "kritik" && !r.is_container).length} tone="warn" />
        <Stat label="Eksi stok" value={all.filter((r) => r.status === "negatif").length} tone="danger" />
        <Stat label="Yavaş hareket" value={all.filter((r) => r.speed === "yavas").length} />
        {isAdmin ? <Stat label="Stok değeri (maliyet)" value={formatTRY(value)} /> : null}
      </div>
      <div className="no-print mb-3 flex flex-wrap gap-2">
        {tab("/stok", "Tümü", !sp.durum && !sp.hiz)}
        {tab("/stok?durum=uyari", "Uyarılar", sp.durum === "uyari")}
        {tab("/stok?hiz=hizli", "Hızlı", sp.hiz === "hizli")}
        {tab("/stok?hiz=yavas", "Yavaş", sp.hiz === "yavas")}
      </div>
      <SearchBox placeholder="Ürün ara" />
      <DataTable
        rows={rows}
        rowKey={(r) => r.product_id}
        onRowClick={can(ctx.role, "receiveGoods") ? (r) => `/stok/${r.product_id}` : undefined}
        mobileTitle={(r) => r.name}
        columns={[
          { key: "name", label: "Ürün", hideOnMobile: true, render: (r) => <span>{r.name}{r.is_container ? <Badge tone="brand" className="ml-2">Boş kap</Badge> : null}</span> },
          { key: "qty", label: "Stok", align: "right", render: (r) => (
            <span className={r.status === "negatif" ? "font-semibold text-danger" : r.status === "kritik" ? "font-semibold text-warn" : ""}>
              {formatNumber(r.qty)} {r.base_unit_name.toLocaleLowerCase("tr-TR")}
            </span>
          ) },
          { key: "crit", label: "Kritik / öneri", align: "right", render: (r) => `${r.critical_level ?? "—"} / ${r.suggested_critical ?? "—"}` },
          { key: "sold", label: "30 gün satış", align: "right", render: (r) => formatNumber(r.sold_qty) },
          { key: "days", label: "Kaç günlük", align: "right", render: (r) => (r.days_of_stock === null ? "—" : formatNumber(r.days_of_stock)) },
          { key: "speed", label: "Hız", render: (r) => (r.speed ? <Badge tone={r.speed === "hizli" ? "ok" : r.speed === "yavas" ? "warn" : "neutral"}>{SPEED[r.speed]}</Badge> : "—") },
          ...(isAdmin ? [{ key: "val", label: "Değer", align: "right" as const, render: (r: Row) => formatTRY(r.stock_value) }] : []),
        ]}
      />
    </div>
  );
}
