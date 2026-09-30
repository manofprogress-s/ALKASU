import Link from "next/link";
import { AlertTriangle, ShoppingCart, Truck } from "lucide-react";
import { getContext } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Card, PageHeader, Stat } from "@/components/ui/card";
import { formatDate, formatTRY } from "@/lib/format";
import { can } from "@/lib/roles";

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
}

export default async function HomePage({ searchParams }: { searchParams: Promise<{ yetki?: string }> }) {
  const ctx = await getContext();
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("dashboard", { p_business: ctx.businessId });
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
      {ctx.role === "depo" ? (
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
        <Alert tone="warn">Son 7 günde {d.offline_limit_alerts} çevrimdışı satış veresiye limitini aştı.</Alert>
      ) : null}
    </div>
  );
}
