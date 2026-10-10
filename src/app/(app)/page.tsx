import Link from "next/link";
import { AlertTriangle, ClipboardList, ShoppingCart, Store, Truck } from "lucide-react";
import { getContext } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Card, PageHeader, Stat } from "@/components/ui/card";
import { formatDate, formatTRY } from "@/lib/format";
import { can } from "@/lib/roles";
import { CustomerHome } from "@/components/orders/customer-home";

interface Dashboard {
  today: string;
  critical_count: number;
  negative_count: number;
  sales_count?: number;
  net_revenue?: number;
  cash?: number;
  pos?: number;
  credit?: number;
  deposit?: number;
  gross_profit?: number | null;
  receivables_total?: number;
  pending_purchases?: number;
  open_return_requests?: number;
  offline_limit_alerts?: number;
  my_sales_count?: number;
  my_sales_total?: number;
  cash_session?: { status: string; expected_cash?: number; opening_cash?: number };
  orders_today?: number;
  my_open_orders?: number;
  unassigned_orders?: number;
  balance?: number;
  open_orders?: number;
  containers?: number;
  pending_approval?: number;
  dealer_open?: number;
}

export default async function HomePage({ searchParams }: { searchParams: Promise<{ yetki?: string; hosgeldin?: string; siparis?: string; uyari?: string }> }) {
  const ctx = await getContext();
  const sp = await searchParams;
  if (ctx.role === "musteri") return <CustomerHome name={ctx.displayName} welcome={!!sp.hosgeldin} orderNo={sp.siparis} warning={sp.uyari} />;
  const supabase = await supabaseServer();
  const [{ data, error }, pendingReq] = await Promise.all([
    supabase.rpc("dashboard", { p_business: ctx.businessId }),
    ctx.role === "bayi" && ctx.customerId
      ? supabase.from("customer_requests").select("id", { count: "exact", head: true }).eq("dealer_id", ctx.customerId).eq("status", "bekliyor")
      : Promise.resolve({ count: 0 }),
  ]);
  const d = (data ?? {}) as Dashboard;

  return (
    <div className="space-y-4">
      <PageHeader title={`Merhaba, ${ctx.displayName}`} subtitle={formatDate(d.today ?? new Date())} />
      {sp.yetki === "yok" ? <Alert tone="warn">Bu sayfa için yetkiniz yok.</Alert> : null}
      {error ? <Alert>{error.message}</Alert> : null}

      {can(ctx.role, "sell") ? (
        <Link href="/satis" className="flex items-center justify-center gap-3 rounded-2xl bg-brand p-5 text-lg font-semibold text-white shadow-sm active:scale-[0.99]">
          <ShoppingCart className="h-6 w-6" /> Yeni satış
        </Link>
      ) : null}
      {ctx.role === "bayi" ? (
        <>
          {pendingReq.count ? (
            <Link href="/musterilerim" className="block">
              <Alert tone="warn">Merkezden onayınızı bekleyen {pendingReq.count} müşteri önerisi var. İncelemek için dokunun →</Alert>
            </Link>
          ) : null}
          <Link href="/siparisler/yeni" className="flex items-center justify-center gap-3 rounded-2xl bg-brand p-5 text-lg font-semibold text-white shadow-sm active:scale-[0.99]">
            <ClipboardList className="h-6 w-6" /> Yeni sipariş
          </Link>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
            <Stat label="Cari bakiyem" value={formatTRY(d.balance)} hint={<Link href="/hesabim" className="text-brand">Ekstre →</Link>} tone={(d.balance ?? 0) > 0 ? "warn" : undefined} />
            <Stat label="Bana atanan teslimat" value={d.dealer_open ?? 0} hint={<Link href="/siparisler?tur=teslimat" className="text-brand">Teslimatlar →</Link>} tone={d.dealer_open ? "warn" : undefined} />
            <Stat label="Açık siparişlerim" value={d.open_orders ?? 0} hint={<Link href="/siparisler?tur=alim" className="text-brand">Siparişler →</Link>} />
            <Stat label="Bendeki damacana/kap" value={d.containers ?? 0} />
          </div>
        </>
      ) : null}
      {ctx.role === "yonetici" ? (
        <Link href="/urunler/magaza" className="flex items-center justify-between gap-3 rounded-2xl border border-border bg-surface p-4 active:scale-[0.99]">
          <span className="flex items-center gap-3">
            <Store className="h-6 w-6 text-brand" />
            <span>
              <span className="block font-semibold">Mağaza düzeni</span>
              <span className="block text-sm text-muted">Müşterinin sipariş ekranındaki ürünleri düzenle</span>
            </span>
          </span>
          <span className="text-brand">→</span>
        </Link>
      ) : null}
      {ctx.role !== "bayi" && d.my_open_orders !== undefined && can(ctx.role, "orders") ? (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
          <Stat label="Bana atanan açık sipariş" value={d.my_open_orders ?? 0} hint={<Link href="/siparisler?atanan=ben" className="text-brand">Teslimatlarım →</Link>} tone={d.my_open_orders ? "warn" : undefined} />
          <Stat label="Bugün teslim edilecek" value={d.orders_today ?? 0} hint={<Link href="/siparisler" className="text-brand">Siparişler →</Link>} />
          {d.pending_approval ? (
            <Stat label="Onay bekleyen (internet)" value={d.pending_approval} hint={<Link href="/siparisler?durum=onay_bekliyor" className="text-brand">Onayla →</Link>} tone="warn" />
          ) : null}
          {d.unassigned_orders !== undefined ? (
            <Stat label="Atanmamış sipariş" value={d.unassigned_orders} hint={<Link href="/siparisler?atanan=yok" className="text-brand">Ata →</Link>} tone={d.unassigned_orders ? "warn" : undefined} />
          ) : null}
        </div>
      ) : null}
      {ctx.role === "depo" || ctx.role === "sevkiyat" ? (
        <Link href="/mal-kabul/yeni" className="flex items-center justify-center gap-3 rounded-2xl bg-brand p-5 text-lg font-semibold text-white">
          <Truck className="h-6 w-6" /> Mal kabul
        </Link>
      ) : null}

      {d.net_revenue !== undefined ? (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Bugünkü satış" value={formatTRY(d.net_revenue)} hint={`${d.sales_count ?? 0} fiş`} />
          {d.gross_profit !== null && d.gross_profit !== undefined ? <Stat label="Brüt kâr" value={formatTRY(d.gross_profit)} tone="ok" /> : null}
          <Stat label="Nakit / POS" value={formatTRY(d.cash)} hint={`POS ${formatTRY(d.pos)}`} />
          <Stat label="Veresiye satış" value={formatTRY(d.credit)} hint={`Depozito ${formatTRY(d.deposit)}`} />
        </div>
      ) : null}

      {d.my_sales_count !== undefined ? (
        <div className="grid grid-cols-2 gap-3">
          <Stat label="Bugün sattığım" value={formatTRY(d.my_sales_total)} hint={`${d.my_sales_count} fiş`} />
        </div>
      ) : null}

      {ctx.role === "yonetici" ? (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat
            label="Kasada beklenen"
            value={d.cash_session?.status === "acik" ? formatTRY(d.cash_session.expected_cash) : "Gün açılmadı"}
            hint={<Link href="/kasa" className="text-brand">Kasa →</Link>}
          />
          <Stat label="Toplam veresiye alacağı" value={formatTRY(d.receivables_total)} hint={<Link href="/raporlar/veresiye" className="text-brand">Ayrıntı →</Link>} />
          <Stat label="Fiyat onayı bekleyen" value={d.pending_purchases ?? 0} hint={<Link href="/mal-kabul" className="text-brand">Mal kabul →</Link>} tone={d.pending_purchases ? "warn" : undefined} />
          <Stat label="İade talebi" value={d.open_return_requests ?? 0} hint={<Link href="/satislar?talep=1" className="text-brand">Satışlar →</Link>} tone={d.open_return_requests ? "warn" : undefined} />
        </div>
      ) : null}

      {(d.critical_count ?? 0) + (d.negative_count ?? 0) > 0 ? (
        <Link href="/stok?durum=uyari">
          <Card className="flex items-center gap-3 border-warn/40 bg-warn-soft">
            <AlertTriangle className="h-6 w-6 text-warn" />
            <div className="text-sm">
              <div className="font-semibold text-warn">Stok uyarısı</div>
              <div className="text-text">
                {d.critical_count ?? 0} ürün kritik seviyede{d.negative_count ? `, ${d.negative_count} ürün eksi stokta` : ""}
              </div>
            </div>
          </Card>
        </Link>
      ) : null}
      {d.offline_limit_alerts ? (
        <Alert tone="warn">Son 7 günde {d.offline_limit_alerts} satış (çevrimdışı satış veya sipariş teslimatı) veresiye limitini aştı.</Alert>
      ) : null}
    </div>
  );
}
