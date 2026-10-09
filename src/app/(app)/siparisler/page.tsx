import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Badge, PageHeader } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDate, formatTRY, todayISO } from "@/lib/format";
import { loadAssignees, loadDealers, ORDER_STATUS, type OrderStatus, type Assignee, type Dealer } from "@/lib/orders";
import { can } from "@/lib/roles";
import { cn } from "@/lib/cn";

export const metadata = { title: "Siparişler" };

interface Row {
  id: string;
  no: number;
  delivery_date: string;
  status: OrderStatus;
  assignee: string | null;
  dealer_customer_id: string | null;
  route_seq: number | null;
  source: string;
  customers: { name: string; code: string } | null;
  order_items: { qty: number; unit_price: number; products: { name: string } | null; product_units: { name: string } | null }[];
}

type Params = { durum?: string; atanan?: string; gun?: string; tur?: string };

const chip = (on: boolean) => cn("rounded-full px-3 py-1.5 text-sm", on ? "bg-brand text-white" : "bg-surface-2");
const statusTone = (s: OrderStatus) => (s === "acik" ? "brand" : s === "teslim_edildi" ? "ok" : s === "onay_bekliyor" ? "warn" : "neutral");

export default async function OrdersPage({ searchParams }: { searchParams: Promise<Params> }) {
  const ctx = await requirePermission("orders");
  const sp = await searchParams;
  const isDealer = ctx.role === "bayi";
  const isCustomer = ctx.role === "musteri";
  const isStaff = !isDealer && !isCustomer;
  // Bayi: "teslimat" = kendisine atanan ev müşterisi siparişleri, "alim" = bizden kendi siparişleri
  const tur = isDealer ? (sp.tur === "alim" ? "alim" : sp.tur === "musterilerim" ? "musterilerim" : "teslimat") : null;
  const durum = (sp.durum ?? (isCustomer ? "tumu" : "acik")) as OrderStatus | "tumu";
  const routeSorted = (sp.atanan === "ben" || tur === "teslimat") && durum === "acik";

  const supabase = await supabaseServer();
  // Bayinin kendi müşterileri (RLS'e ek olarak açıkça filtrelenir)
  const myCustomerIds =
    tur === "musterilerim" && ctx.customerId
      ? (((await supabase.from("customers").select("id").eq("owner_dealer_id", ctx.customerId)).data ?? []) as { id: string }[]).map((c) => c.id)
      : [];
  let q = supabase
    .from("orders")
    .select("id, no, delivery_date, status, assignee, dealer_customer_id, route_seq, source, customers!orders_customer_id_fkey(name, code), order_items(qty, unit_price, products(name), product_units(name))")
    .eq("business_id", ctx.businessId);
  q = routeSorted
    ? q.order("route_seq", { ascending: true, nullsFirst: false }).order("delivery_date", { ascending: true })
    : q.order("delivery_date", { ascending: durum === "acik" || durum === "onay_bekliyor" }).order("no", { ascending: false });
  q = q.limit(300);
  if (durum !== "tumu") q = q.eq("status", durum);
  if (sp.atanan === "ben") q = q.eq("assignee", ctx.userId);
  if (sp.atanan === "yok") q = q.is("assignee", null).is("dealer_customer_id", null);
  if (sp.atanan === "bayi") q = q.not("dealer_customer_id", "is", null);
  if (sp.gun === "bugun") q = q.lte("delivery_date", todayISO());
  if (tur === "teslimat" && ctx.customerId) q = q.eq("dealer_customer_id", ctx.customerId);
  if (tur === "alim" && ctx.customerId) q = q.eq("customer_id", ctx.customerId);
  if (tur === "musterilerim" && ctx.customerId) q = q.in("customer_id", myCustomerIds.length ? myCustomerIds : ["00000000-0000-0000-0000-000000000000"]);

  const [{ data }, assignees, dealers] = await Promise.all([
    q,
    isStaff ? loadAssignees(supabase, ctx.businessId) : Promise.resolve([] as Assignee[]),
    isStaff ? loadDealers(supabase, ctx.businessId) : Promise.resolve([] as Dealer[]),
  ]);
  const people = new Map(assignees.map((a) => [a.user_id, a.display_name]));
  const dealerNames = new Map(dealers.map((d) => [d.id, d.name]));
  const rows = ((data ?? []) as unknown as Row[]).map((o) => ({
    ...o,
    total: o.order_items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0),
    summary: o.order_items.map((i) => `${i.qty} ${i.product_units?.name ?? ""} ${i.products?.name ?? ""}`).join(", "),
  }));
  const today = todayISO();
  const link = (patch: Partial<Params>) => {
    const p = new URLSearchParams();
    const merged: Params = { durum: sp.durum, atanan: sp.atanan, gun: sp.gun, tur: sp.tur, ...patch };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    const s = p.toString();
    return `/siparisler${s ? `?${s}` : ""}`;
  };
  const statuses: (OrderStatus | "tumu")[] = isStaff || isDealer
    ? ["onay_bekliyor", "acik", "teslim_edildi", "iptal", "tumu"]
    : ["acik", "teslim_edildi", "iptal", "tumu"];
  const owner = (r: Row) =>
    r.dealer_customer_id ? <Badge tone="brand">Bayi: {dealerNames.get(r.dealer_customer_id) ?? "—"}</Badge>
      : r.assignee ? people.get(r.assignee) ?? "—"
        : <Badge tone="warn">Atanmadı</Badge>;

  return (
    <div>
      <PageHeader
        title={isCustomer ? "Siparişlerim" : tur === "teslimat" ? "Teslimatlarım" : tur === "musterilerim" ? "Müşterilerimin siparişleri" : isDealer ? "Bizden alımlarım" : "Siparişler"}
        subtitle={`${rows.length} sipariş${routeSorted ? " · rota sırasına göre" : ""}`}
        actions={
          <>
            {can(ctx.role, "routes") ? <Link href="/rota" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Rota</Link> : null}
            <Link href="/siparisler/yeni" className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Yeni sipariş</Link>
          </>
        }
      />
      <div className="no-print mb-3 flex flex-wrap gap-2">
        {isDealer ? (
          <>
            <Link href={link({ tur: undefined })} className={chip(tur === "teslimat")}>Bana atanan teslimatlar</Link>
            <Link href={link({ tur: "musterilerim" })} className={chip(tur === "musterilerim")}>Müşterilerimin siparişleri</Link>
            <Link href={link({ tur: "alim" })} className={chip(tur === "alim")}>Bizden alımlarım</Link>
            <span className="mx-1 border-l border-border" />
          </>
        ) : null}
        {statuses.map((s) => (
          <Link key={s} href={link({ durum: s === (isCustomer ? "tumu" : "acik") ? undefined : s })} className={chip(durum === s)}>
            {s === "tumu" ? "Tümü" : ORDER_STATUS[s]}
          </Link>
        ))}
        {isStaff ? (
          <>
            <span className="mx-1 border-l border-border" />
            <Link href={link({ atanan: sp.atanan === "ben" ? undefined : "ben" })} className={chip(sp.atanan === "ben")}>Bana atanan</Link>
            <Link href={link({ atanan: sp.atanan === "yok" ? undefined : "yok" })} className={chip(sp.atanan === "yok")}>Atanmamış</Link>
            <Link href={link({ atanan: sp.atanan === "bayi" ? undefined : "bayi" })} className={chip(sp.atanan === "bayi")}>Bayide</Link>
          </>
        ) : null}
        {!isCustomer ? (
          <Link href={link({ gun: sp.gun === "bugun" ? undefined : "bugun" })} className={chip(sp.gun === "bugun")}>Bugün ve gecikmiş</Link>
        ) : null}
      </div>
      <DataTable
        rows={rows}
        rowKey={(r) => r.id}
        onRowClick={(r) => `/siparisler/${r.id}`}
        mobileTitle={(r) => `${routeSorted && r.route_seq ? `${r.route_seq}. ` : ""}#${r.no} · ${r.customers?.name ?? ""}`}
        columns={[
          ...(routeSorted ? [{ key: "r", label: "Sıra", hideOnMobile: true, render: (r: Row) => r.route_seq ?? "—" }] : []),
          { key: "no", label: "No", hideOnMobile: true, render: (r) => `#${r.no}` },
          ...(isCustomer || tur === "alim" ? [] : [{ key: "c", label: "Müşteri", hideOnMobile: true, render: (r: Row) => (
            <span>{r.customers?.name ?? ""} {r.source === "online" ? <Badge>İnternet</Badge> : null}</span>
          ) }]),
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
          ...(isStaff ? [{ key: "a", label: "Teslim eden", render: (r: Row) => owner(r) }] : []),
          { key: "t", label: "Tutar", align: "right", render: (r) => formatTRY(r.total) },
          {
            key: "s",
            label: "Durum",
            render: (r) => <Badge tone={statusTone(r.status)}>{isCustomer && r.status === "acik" && r.dealer_customer_id ? "Yolda" : ORDER_STATUS[r.status]}</Badge>,
          },
        ]}
        empty={tur === "teslimat" ? "Size atanmış açık teslimat yok" : "Sipariş yok"}
      />
    </div>
  );
}
