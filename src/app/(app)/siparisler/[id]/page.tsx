import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Badge, Card, PageHeader } from "@/components/ui/card";
import { formatDate, formatDateTime, formatTRY } from "@/lib/format";
import { loadAssignees, loadDealerNames, loadDealers, ORDER_STATUS, type OrderStatus, type Assignee, type Dealer } from "@/lib/orders";
import { can, PRICE_LISTS, type PriceList } from "@/lib/roles";
import { ApprovalActions, DealerActions, OrderActions, type DeliverItem } from "@/components/orders/order-actions";
import { LocationView } from "@/components/geo/location-view";
import { toLatLng } from "@/lib/geo";

interface OrderRow {
  id: string;
  no: number;
  customer_id: string;
  delivery_date: string;
  assignee: string | null;
  status: OrderStatus;
  address: string | null;
  note: string | null;
  price_list: PriceList;
  created_by: string | null;
  created_at: string;
  delivered_by: string | null;
  delivered_at: string | null;
  sale_id: string | null;
  dealer_customer_id: string | null;
  dealer_note: string | null;
  requested_dealer_id: string | null;
  source: string;
  cancelled_at: string | null;
  cancel_reason: string | null;
  customers: { name: string; code: string; phone: string | null; credit_limit: number; unlimited_credit: boolean; latitude: number | null; longitude: number | null; owner_dealer_id: string | null; channel: string } | null;
  order_items: {
    id: string;
    line_no: number;
    product_id: string;
    unit_id: string;
    qty: number;
    unit_price: number;
    products: { name: string; deposit_amount: number | null; empty_product_id: string | null } | null;
    product_units: { name: string; factor: number } | null;
  }[];
}

export default async function OrderPage({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("orders");
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from("orders")
    .select(
      "*, customers!orders_customer_id_fkey(name, code, phone, credit_limit, unlimited_credit, latitude, longitude, owner_dealer_id, channel), order_items(id, line_no, product_id, unit_id, qty, unit_price, products(name, deposit_amount, empty_product_id), product_units(name, factor))",
    )
    .eq("id", id)
    .maybeSingle();
  if (!data) notFound();
  const o = data as unknown as OrderRow;
  const isDealer = ctx.role === "bayi";
  const isCustomer = ctx.role === "musteri";
  const isStaff = !isDealer && !isCustomer;
  // bayi/müşterinin kendi siparişi; bayi için kendi müşterisinin siparişi de
  const isMine = o.customer_id === ctx.customerId || (isDealer && !!ctx.customerId && o.customers?.owner_dealer_id === ctx.customerId);
  const isMyDelivery = isDealer && !!ctx.customerId && o.dealer_customer_id === ctx.customerId;
  const open = o.status === "acik" || o.status === "onay_bekliyor";
  const [assignees, dealers, bal, cont, routing] = await Promise.all([
    isStaff ? loadAssignees(supabase, ctx.businessId) : Promise.resolve([] as Assignee[]),
    isStaff ? loadDealers(supabase, ctx.businessId) : Promise.resolve([] as Dealer[]),
    supabase.from("customer_balances").select("balance").eq("customer_id", o.customer_id).maybeSingle(),
    supabase.from("container_balances").select("product_id, qty, amount").eq("customer_id", o.customer_id),
    // Yönlendirme geçmişi: yalnızca yönetici görür (RLS, G-17)
    ctx.role === "yonetici"
      ? supabase.from("order_routing_log").select("id, from_dealer, to_dealer, special, note, created_by, created_at").eq("order_id", o.id).order("created_at")
      : Promise.resolve({ data: [] }),
  ]);
  const routes = (routing.data ?? []) as { id: number; from_dealer: string | null; to_dealer: string | null; special: boolean; note: string | null; created_by: string | null; created_at: string }[];
  const names = new Map(assignees.map((a) => [a.user_id, a.display_name]));
  const items = [...o.order_items].sort((a, b) => a.line_no - b.line_no);
  const total = items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0);
  const canDeliver = o.status === "acik" && !o.dealer_customer_id && can(ctx.role, "deliver") && (ctx.role === "yonetici" || o.assignee === ctx.userId);
  const notTakenByOther = !o.dealer_customer_id || o.dealer_customer_id === ctx.customerId;
  const canEdit = open && (isStaff || (isMine && notTakenByOther));
  const dealerName = dealers.find((d) => d.id === o.dealer_customer_id)?.name;
  const dealerNames = isDealer && o.requested_dealer_id ? await loadDealerNames(supabase, ctx.businessId) : dealers;
  const requestedName = o.requested_dealer_id ? dealerNames.find((d) => d.id === o.requested_dealer_id)?.name ?? "Bayi" : null;

  const deliverItems: DeliverItem[] = items.map((i) => ({
    id: i.id,
    productId: i.product_id,
    unitId: i.unit_id,
    productName: i.products?.name ?? "",
    unitName: i.product_units?.name ?? "",
    factor: i.product_units?.factor ?? 1,
    qty: i.qty,
    unitPrice: Number(i.unit_price),
    deposit: i.products?.deposit_amount === null || i.products?.deposit_amount === undefined ? null : Number(i.products.deposit_amount),
    emptyProductId: i.products?.empty_product_id ?? null,
  }));

  return (
    <div className="space-y-4">
      <PageHeader
        title={`Sipariş #${o.no}`}
        subtitle={
          <span className="flex flex-wrap items-center gap-2">
            <Badge tone={o.status === "acik" ? "brand" : o.status === "teslim_edildi" ? "ok" : o.status === "onay_bekliyor" ? "warn" : "neutral"}>
              {isCustomer && o.status === "acik" && o.dealer_customer_id ? "Yolda" : ORDER_STATUS[o.status]}
            </Badge>
            {o.source === "online" && isStaff ? <Badge>İnternet siparişi</Badge> : null}
            Teslim: {formatDate(o.delivery_date)}
            {o.price_list !== "perakende" ? <Badge tone="ok">{PRICE_LISTS[o.price_list]} fiyatı</Badge> : null}
          </span>
        }
        actions={
          canEdit ? (
            <Link href={`/siparisler/${o.id}/duzenle`} className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Düzenle</Link>
          ) : null
        }
      />

      <div className="grid gap-4 lg:grid-cols-[1fr_340px]">
        <Card className="space-y-3">
          <div>
            <div className="text-sm text-muted">Müşteri</div>
            {!isStaff ? (
              <div className="font-semibold">{o.customers?.name}</div>
            ) : (
              <Link href={`/musteriler/${o.customer_id}`} className="font-semibold text-brand">{o.customers?.name}</Link>
            )}
            {o.customers?.phone ? <div className="text-sm"><a className="text-brand" href={`tel:${o.customers.phone}`}>{o.customers.phone}</a></div> : null}
          </div>
          {o.address ? <div><div className="text-sm text-muted">Adres</div><div className="whitespace-pre-line">{o.address}</div></div> : null}
          <LocationView point={toLatLng(o.customers?.latitude, o.customers?.longitude)} />
          {o.note ? <div><div className="text-sm text-muted">Not</div><div>{o.note}</div></div> : null}
          <table className="w-full text-sm">
            <thead className="text-left text-xs text-muted">
              <tr><th className="py-1">Ürün</th><th className="py-1 text-right">Miktar</th><th className="py-1 text-right">Fiyat</th><th className="py-1 text-right">Tutar</th></tr>
            </thead>
            <tbody className="divide-y divide-border">
              {items.map((i) => (
                <tr key={i.id}>
                  <td className="py-1.5">{i.products?.name}</td>
                  <td className="num py-1.5 text-right">{i.qty} {i.product_units?.name}</td>
                  <td className="num py-1.5 text-right">{formatTRY(i.unit_price)}</td>
                  <td className="num py-1.5 text-right">{formatTRY(Number(i.qty) * Number(i.unit_price))}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="font-semibold"><td className="pt-2" colSpan={3}>Ürün tutarı</td><td className="num pt-2 text-right">{formatTRY(total)}</td></tr>
            </tfoot>
          </table>
        </Card>

        <div className="space-y-3">
          <Card className="space-y-1 text-sm">
            {isStaff ? (
              <div className="flex justify-between gap-2"><span className="text-muted">Teslim eden</span><span>{dealerName ? <Badge tone="brand">Bayi: {dealerName}</Badge> : o.assignee ? names.get(o.assignee) ?? "—" : <Badge tone="warn">Atanmadı</Badge>}</span></div>
            ) : null}
            {o.dealer_note && (isStaff || isMyDelivery) ? <Alert tone="neutral">Bayi notu: {o.dealer_note}</Alert> : null}
            <div className="flex justify-between gap-2"><span className="text-muted">Oluşturma</span><span>{formatDateTime(o.created_at)}</span></div>
            {o.delivered_at ? (
              <div className="flex justify-between gap-2"><span className="text-muted">Teslim</span><span>{formatDateTime(o.delivered_at)}{o.delivered_by ? ` · ${names.get(o.delivered_by) ?? ""}` : ""}</span></div>
            ) : null}
            {o.sale_id && isStaff ? (
              <div className="flex justify-between gap-2"><span className="text-muted">Satış fişi</span><Link className="text-brand" href={`/satislar/${o.sale_id}`}>Görüntüle →</Link></div>
            ) : null}
            {o.cancelled_at ? <Alert tone="neutral">İptal: {formatDateTime(o.cancelled_at)} · {o.cancel_reason}</Alert> : null}
          </Card>
          {routes.length ? (
            <Card className="space-y-1 text-sm">
              <h2 className="font-semibold">Yönlendirme geçmişi</h2>
              {routes.map((r) => (
                <div key={r.id} className="border-t border-border pt-1 first:border-0">
                  <div className="flex flex-wrap items-center gap-1">
                    {r.special ? <Badge tone="warn">Özel</Badge> : null}
                    <span>{r.from_dealer ? dealers.find((d) => d.id === r.from_dealer)?.name ?? "Bayi" : "Depo"} → {r.to_dealer ? dealers.find((d) => d.id === r.to_dealer)?.name ?? "Bayi" : "Depo"}</span>
                  </div>
                  <div className="text-xs text-muted">{formatDateTime(r.created_at)} · {r.created_by ? names.get(r.created_by) ?? "" : ""}{r.note ? ` · ${r.note}` : ""}</div>
                </div>
              ))}
            </Card>
          ) : null}
          {o.status === "onay_bekliyor" && isStaff ? (
            <ApprovalActions
              orderId={o.id}
              orderNo={o.no}
              phone={o.customers?.phone ?? null}
              note={o.source === "bayi" ? `Bayi siparişi · teslim edecek: ${requestedName ?? "Merkez (biz)"}` : undefined}
            />
          ) : null}
          {o.status === "onay_bekliyor" && isDealer ? (
            <Alert tone="warn">Onay bekliyor · teslim edecek: {requestedName ?? "Merkez (Alay Ticaret)"}</Alert>
          ) : null}
          {o.status === "acik" && isMyDelivery ? <DealerActions orderId={o.id} orderNo={o.no} /> : null}
          {open && (isStaff ? o.status === "acik" : isMine) ? (
            <OrderActions
              orderId={o.id}
              orderNo={o.no}
              customerName={o.customers?.name ?? ""}
              assignee={o.assignee}
              assignees={assignees}
              canAssign={isStaff && can(ctx.role, "orderAssign")}
              canDeliver={canDeliver}
              canAssignDealer={isStaff && can(ctx.role, "orderAssign")}
              canSpecial={ctx.role === "yonetici" || ctx.role === "sevkiyat"}
              customerChannel={o.customers?.channel}
              ownerDealerId={o.customers?.owner_dealer_id ?? null}
              canCancel={isStaff || notTakenByOther}
              dealers={dealers.filter((d) => d.id !== o.customer_id)}
              dealerId={o.dealer_customer_id}
              items={deliverItems}
              balance={Number(bal.data?.balance ?? 0)}
              creditLimit={o.customers?.unlimited_credit ? null : Number(o.customers?.credit_limit ?? 0)}
              containers={((cont.data ?? []) as { product_id: string; qty: number; amount: number }[]).map((c) => ({ productId: c.product_id, qty: c.qty, amount: Number(c.amount) }))}
            />
          ) : null}
          {isCustomer && o.status === "onay_bekliyor" ? (
            <Alert tone="warn">Siparişiniz alındı. İlk siparişinizi telefonla teyit edip yola çıkaracağız.</Alert>
          ) : null}
          {o.status === "acik" && !canDeliver && isStaff && !o.dealer_customer_id ? (
            <div className="text-xs text-muted">Teslimatı yalnızca atanan kişi veya yönetici kaydedebilir.</div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
