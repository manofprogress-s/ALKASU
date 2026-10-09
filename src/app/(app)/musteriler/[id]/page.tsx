import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Card, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { formatDateTime, formatTRY } from "@/lib/format";
import { CustomerForm, type AssigneeOption } from "@/components/customers/customer-form";
import { Badge } from "@/components/ui/card";
import { CHANNELS, PRICE_LISTS, type Channel, type PriceList } from "@/lib/roles";
import { CustomerActions } from "@/components/customers/customer-actions";
import { ContainerAdjust } from "@/components/customers/container-adjust";
import { CustomerPrices } from "@/components/customers/customer-prices";
import { loadOrderProducts } from "@/lib/orders";
import { LocationView } from "@/components/geo/location-view";
import { toLatLng } from "@/lib/geo";
import { ExportButton } from "@/components/reports/export-button";

export default async function CustomerPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ kanal?: string }> }) {
  const ctx = await requirePermission("customers");
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: au } = await supabase.rpc("assignable_users", { p_business: ctx.businessId });
  const assignees = (au ?? []) as AssigneeOption[];
  if (id === "yeni") {
    return (
      <div className="space-y-4">
        <PageHeader title="Yeni müşteri" />
        <CustomerForm initial={null} defaultChannel={(await searchParams).kanal} canSetLimit={ctx.role === "yonetici"} assignees={assignees} />
      </div>
    );
  }
  const [{ data: c }, { data: sum }, { data: st }, { data: pays }, { data: depProducts }, { data: cprices }, products] = await Promise.all([
    supabase.from("customers").select("*").eq("id", id).maybeSingle(),
    supabase.rpc("customer_summary", { p_customer: id }),
    supabase.rpc("customer_statement", { p_customer: id }),
    supabase.from("customer_payments").select("id, method, amount, status, created_at, note").eq("customer_id", id).order("created_at", { ascending: false }).limit(20),
    supabase.from("products").select("id, name").eq("business_id", ctx.businessId).not("deposit_amount", "is", null).eq("active", true).order("name"),
    supabase.from("customer_prices").select("unit_id, price").eq("customer_id", id),
    loadOrderProducts(supabase, ctx.businessId),
  ]);
  if (!c) notFound();
  const summary = sum as { balance: number; containers: { product_id: string; product_name: string; qty: number; amount: number }[] };
  const statement = ((st ?? []) as { at: string; description: string; debit: number | null; credit: number | null; balance: number }[]).reverse();

  return (
    <div className="space-y-4">
      <PageHeader
        title={c.name}
        subtitle={
          <span className="flex flex-wrap items-center gap-2">
            {c.code}{c.phone ? ` · ${c.phone}` : ""}
            <Badge tone={c.channel === "bayi" ? "brand" : "neutral"}>{CHANNELS[c.channel as Channel]}</Badge>
            {c.price_list !== "perakende" ? <Badge tone="ok">{PRICE_LISTS[c.price_list as PriceList]} fiyatı</Badge> : null}
            {c.regions ? <span className="text-xs">Bölge: {c.regions}</span> : null}
          </span>
        }
        actions={<Link href={`/siparisler/yeni?musteri=${c.id}`} className="inline-flex h-11 items-center rounded-xl bg-brand px-4 font-medium text-white">Sipariş gir</Link>}
      />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Veresiye bakiyesi" value={formatTRY(summary.balance)} tone={summary.balance > 0 ? "warn" : undefined} />
        <Stat label="Limit" value={c.unlimited_credit ? "Limitsiz" : formatTRY(c.credit_limit)} />
        {summary.containers.map((k) => (
          <Stat key={k.product_id} label={`Elindeki kap · ${k.product_name}`} value={k.qty} hint={`Ödenen depozito ${formatTRY(k.amount)}`} />
        ))}
        {c.channel !== "perakende" || c.dispenser_count > 0 ? <Stat label="Sebil" value={c.dispenser_count} /> : null}
      </div>
      {c.address || c.latitude !== null ? (
        <Card className="space-y-2">
          {c.address ? <div className="whitespace-pre-line text-sm">{c.address}</div> : null}
          <LocationView point={toLatLng(c.latitude, c.longitude)} />
        </Card>
      ) : null}
      {c.channel !== "perakende" || (cprices ?? []).length ? (
        <CustomerPrices
          customerId={c.id}
          prices={Object.fromEntries(((cprices ?? []) as { unit_id: string; price: number }[]).map((r) => [r.unit_id, Number(r.price)]))}
          products={products}
          priceList={c.price_list}
          canEdit={ctx.role === "yonetici"}
        />
      ) : null}
      {ctx.role === "yonetici" ? (
        <ContainerAdjust
          customerId={c.id}
          products={(depProducts ?? []) as { id: string; name: string }[]}
          current={Object.fromEntries(summary.containers.map((k) => [k.product_id, k.qty]))}
        />
      ) : null}
      <CustomerActions
        customerId={c.id}
        isAdmin={ctx.role === "yonetici"}
        containers={summary.containers}
        payments={(pays ?? []) as { id: string; method: string; amount: number; status: string; created_at: string }[]}
      />
      <Card>
        <div className="mb-2 flex items-center justify-between">
          <h2 className="font-semibold">Hesap ekstresi</h2>
          <ExportButton filename={`ekstre_${c.code}`} rows={[...statement].reverse().map((s) => ({
            Tarih: formatDateTime(s.at), Açıklama: s.description, Borç: s.debit === null ? null : Number(s.debit), Alacak: s.credit === null ? null : Number(s.credit), Bakiye: Number(s.balance),
          }))} />
        </div>
        <DataTable rows={statement} rowKey={(r) => `${r.at}${r.description}${r.balance}`} mobileTitle={(r) => r.description}
          columns={[
            { key: "t", label: "Tarih", render: (r) => formatDateTime(r.at) },
            { key: "d", label: "Açıklama", hideOnMobile: true, render: (r) => r.description },
            { key: "b", label: "Borç", align: "right", render: (r) => (r.debit ? formatTRY(r.debit) : "") },
            { key: "a", label: "Alacak", align: "right", render: (r) => (r.credit ? formatTRY(r.credit) : "") },
            { key: "s", label: "Bakiye", align: "right", render: (r) => formatTRY(r.balance) },
          ]} empty="Hareket yok" />
      </Card>
      <details className="rounded-2xl border border-border bg-surface p-4">
        <summary className="cursor-pointer font-semibold">Müşteri bilgilerini düzenle</summary>
        <div className="mt-3">
          <CustomerForm canSetLimit={ctx.role === "yonetici"} assignees={assignees} initial={{
            id: c.id, code: c.code, name: c.name, phone: c.phone, address: c.address, tax_no: c.tax_no, note: c.note,
            credit_limit: Number(c.credit_limit), unlimited_credit: c.unlimited_credit, active: c.active,
            channel: c.channel, price_list: c.price_list, regions: c.regions, default_assignee: c.default_assignee,
            location: toLatLng(c.latitude, c.longitude), dispenser_count: c.dispenser_count ?? 0,
          }} />
        </div>
      </details>
    </div>
  );
}
