import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDate, formatTRY, todayISO } from "@/lib/format";
import { loadAssignees, ORDER_STATUS, type OrderStatus } from "@/lib/orders";
import { cn } from "@/lib/cn";

export const metadata = { title: "Siparişler" };

interface Row {
  id: string;
  no: number;
  delivery_date: string;
  status: OrderStatus;
  assignee: string | null;
  address: string | null;
  note: string | null;
  customers: { name: string; code: string } | null;
  order_items: { qty: number; unit_price: number; products: { name: string } | null; product_units: { name: string } | null }[];
}

const chip = (on: boolean) => cn("rounded-full px-3 py-1.5 text-sm", on ? "bg-brand text-white" : "bg-surface-2");

export default async function OrdersPage({ searchParams }: { searchParams: Promise<{ durum?: string; atanan?: string; gun?: string }> }) {
  const ctx = await requirePermission("orders");
  const sp = await searchParams;
  const durum = (sp.durum ?? "acik") as OrderStatus | "tumu";
  const supabase = await supabaseServer();
  let q = supabase
    .from("orders")
    .select("id, no, delivery_date, status, assignee, address, note, customers(name, code), order_items(qty, unit_price, products(name), product_units(name))")
    .eq("business_id", ctx.businessId)
    .order("delivery_date", { ascending: durum === "acik" })
    .order("no", { ascending: false })
    .limit(300);
  if (durum !== "tumu") q = q.eq("status", durum);
  if (sp.atanan === "ben") q = q.eq("assignee", ctx.userId);
  if (sp.atanan === "yok") q = q.is("assignee", null);
  if (sp.gun === "bugun") q = q.lte("delivery_date", todayISO());
  const [{ data }, assignees] = await Promise.all([q, loadAssignees(supabase, ctx.businessId)]);
  const names = new Map(assignees.map((a) => [a.user_id, a.display_name]));
  const rows = ((data ?? []) as unknown as Row[]).map((o) => ({
    ...o,
    total: o.order_items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0),
    summary: o.order_items.map((i) => `${i.qty} ${i.product_units?.name ?? ""} ${i.products?.name ?? ""}`).join(", "),
  }));
  const today = todayISO();
  const link = (patch: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    const merged = { durum: sp.durum, atanan: sp.atanan, gun: sp.gun, ...patch };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    const s = p.toString();
    return `/siparisler${s ? `?${s}` : ""}`;
  };
  const isDealer = ctx.role === "bayi";

  return (
    <div>
      <PageHeader
        title={isDealer ? "Siparişlerim" : "Siparişler"}
        subtitle={`${rows.length} sipariş`}
        actions={<Link href="/siparisler/yeni" className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni sipariş</Link>}
      />
      <div className="no-print mb-3 flex flex-wrap gap-2">
        {(["acik", "teslim_edildi", "iptal", "tumu"] as const).map((s) => (
          <Link key={s} href={link({ durum: s === "acik" ? undefined : s })} className={chip(durum === s)}>
            {s === "tumu" ? "Tümü" : ORDER_STATUS[s]}
          </Link>
        ))}
        {!isDealer ? (
          <>
            <span className="mx-1 border-l border-border" />
            <Link href={link({ atanan: sp.atanan === "ben" ? undefined : "ben" })} className={chip(sp.atanan === "ben")}>Bana atanan</Link>
            <Link href={link({ atanan: sp.atanan === "yok" ? undefined : "yok" })} className={chip(sp.atanan === "yok")}>Atanmamış</Link>
          </>
        ) : null}
        <Link href={link({ gun: sp.gun === "bugun" ? undefined : "bugun" })} className={chip(sp.gun === "bugun")}>Bugün ve gecikmiş</Link>
      </div>
      <DataTable
        rows={rows}
        rowKey={(r) => r.id}
        onRowClick={(r) => `/siparisler/${r.id}`}
        mobileTitle={(r) => `#${r.no} · ${r.customers?.name ?? ""}`}
        columns={[
          { key: "no", label: "No", hideOnMobile: true, render: (r) => `#${r.no}` },
          { key: "c", label: "Müşteri", hideOnMobile: true, render: (r) => r.customers?.name ?? "" },
          {
            key: "d",
            label: "Teslim",
            render: (r) => (
              <span className={r.status === "acik" && r.delivery_date < today ? "font-semibold text-danger" : r.delivery_date === today ? "font-semibold" : ""}>
                {r.delivery_date === today ? "Bugün" : formatDate(r.delivery_date)}
              </span>
            ),
          },
          { key: "i", label: "Ürünler", render: (r) => <span className="line-clamp-2">{r.summary}</span> },
          ...(isDealer ? [] : [{ key: "a", label: "Sorumlu", render: (r: (typeof rows)[number]) => (r.assignee ? names.get(r.assignee) ?? "—" : <Badge tone="warn">Atanmadı</Badge>) }]),
          { key: "t", label: "Tutar", align: "right", render: (r) => formatTRY(r.total) },
          {
            key: "s",
            label: "Durum",
            render: (r) => <Badge tone={r.status === "acik" ? "brand" : r.status === "teslim_edildi" ? "ok" : "neutral"}>{ORDER_STATUS[r.status]}</Badge>,
          },
        ]}
        empty="Sipariş yok"
      />
    </div>
  );
}
