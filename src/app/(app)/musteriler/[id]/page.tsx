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
import { PrivacyCard, type PrivacyEvent } from "@/components/customers/privacy";
import { ProposeCustomer, RequestList, type CardValues, type CustomerRequest } from "@/components/customers/dealer-requests";

export default async function CustomerPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ kanal?: string }> }) {
  const ctx = await requirePermission("customers");
  const { id } = await params;
  const supabase = await supabaseServer();
  const loadAssigneeOptions = async () => ((await supabase.rpc("assignable_users", { p_business: ctx.businessId })).data ?? []) as AssigneeOption[];
  if (id === "yeni") {
    const assignees = await loadAssigneeOptions();
    return (
      <div className="space-y-4">
        <PageHeader title="Yeni müşteri" />
        <CustomerForm initial={null} defaultChannel={(await searchParams).kanal} canSetLimit={ctx.role === "yonetici"} assignees={assignees} />
      </div>
    );
  }
  // Tek dalga: tüm okumalar paralel (hız adımı 4)
  const [{ data: c }, { data: sum }, { data: st }, { data: pays }, { data: depProducts }, { data: cprices }, products, { data: pev }, assignees] = await Promise.all([
    supabase.from("customers").select("*").eq("id", id).maybeSingle(),
    supabase.rpc("customer_summary", { p_customer: id }),
    supabase.rpc("customer_statement", { p_customer: id }),
    supabase.from("customer_payments").select("id, method, amount, status, created_at, note").eq("customer_id", id).order("created_at", { ascending: false }).limit(20),
    supabase.from("products").select("id, name").eq("business_id", ctx.businessId).not("deposit_amount", "is", null).eq("active", true).order("name"),
    supabase.from("customer_prices").select("unit_id, price").eq("customer_id", id),
    loadOrderProducts(supabase, ctx.businessId),
    supabase.from("privacy_events").select("kind, channel, notice_version, created_at").eq("customer_id", id).order("created_at", { ascending: false }).limit(50),
    loadAssigneeOptions(),
  ]);
  if (!c) notFound();
  // Bayiye ait kart / bayi kartı: bayinin listesi ve öneriler (G-13..G-15)
  const dealerId: string | null = c.owner_dealer_id ?? (c.channel === "bayi" ? c.id : null);
  const [ownerDealer, dealerCustomers, reqs] = dealerId
    ? await Promise.all([
        c.owner_dealer_id ? supabase.from("customers").select("id, name").eq("id", c.owner_dealer_id).maybeSingle() : Promise.resolve({ data: { id: c.id, name: c.name } }),
        c.channel === "bayi"
          ? supabase.from("customers").select("id, code, name, phone, address, note, latitude, longitude, active").eq("owner_dealer_id", c.id).order("name")
          : Promise.resolve({ data: [] }),
        (c.owner_dealer_id
          ? supabase.from("customer_requests").select("id, customer_id, data, status, requested_at, decided_at, decision_note").eq("customer_id", c.id)
          : supabase.from("customer_requests").select("id, customer_id, data, status, requested_at, decided_at, decision_note").eq("dealer_id", c.id)
        ).order("requested_at", { ascending: false }).limit(20),
      ])
    : [null, null, null];
  const dealerName = (ownerDealer?.data as { name: string } | null)?.name ?? "";
  const ownList = ((dealerCustomers?.data ?? []) as (CardValues & { id: string; code: string; active: boolean })[]);
  const requests = (reqs?.data ?? []) as CustomerRequest[];
  const cardOf = (x: CardValues) => ({ name: x.name, phone: x.phone, address: x.address, note: x.note, latitude: x.latitude, longitude: x.longitude });
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
      {c.channel !== "bayi" ? (
        <PrivacyCard mode="staff" customerId={c.id} marketing={c.marketing_consent} marketingAt={c.marketing_consent_at} events={(pev ?? []) as PrivacyEvent[]} />
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
      {c.channel === "bayi" ? (
        <Card className="space-y-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="font-semibold">Bayinin müşterileri ({ownList.length})</h2>
            <ProposeCustomer dealerId={c.id} dealerName={c.name} />
          </div>
          <p className="text-sm text-muted">Bu liste bayiye aittir. Merkez görebilir; ekleme ve değişiklikler bayinin onayına gider.</p>
          {ownList.length ? (
            <ul className="divide-y divide-border">
              {ownList.map((m) => (
                <li key={m.id} className="flex items-center justify-between gap-2 py-2">
                  <Link href={`/musteriler/${m.id}`} className="min-w-0">
                    <span className="block font-medium">{m.name} {!m.active ? <Badge>Pasif</Badge> : null}</span>
                    <span className="block truncate text-xs text-muted">{m.phone ?? ""} {m.address ?? ""}</span>
                  </Link>
                </li>
              ))}
            </ul>
          ) : null}
        </Card>
      ) : null}
      {dealerId ? (
        <RequestList rows={requests} mode="staff" currentById={c.owner_dealer_id ? { [c.id]: cardOf(c) } : Object.fromEntries(ownList.map((m) => [m.id, cardOf(m)]))} />
      ) : null}
      {c.owner_dealer_id ? (
        <Card className="flex flex-wrap items-center justify-between gap-3">
          <span className="text-sm"><Badge tone="brand">Bayi müşterisi: {dealerName}</Badge> Kart bilgilerini yalnızca bayi değiştirir; siz öneri gönderebilirsiniz.</span>
          <ProposeCustomer dealerId={c.owner_dealer_id} dealerName={dealerName} customerId={c.id} current={cardOf(c)} />
        </Card>
      ) : (
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
      )}
    </div>
  );
}
