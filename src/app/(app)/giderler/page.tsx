import Link from "next/link";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Alert, Badge, Card, PageHeader, Stat } from "@/components/ui/card";
import { DataTable } from "@/components/ui/table";
import { ExpenseCancel, ExpenseForm, type ExpenseCategory } from "@/components/expenses/expense-form";
import { addDaysISO, formatDate, formatTRY, todayISO } from "@/lib/format";
import { addMonths, monthBounds, monthLabel, normalizePeriod, parseMonth } from "@/lib/profit";

export const metadata = { title: "Giderler" };

type Row = {
  id: string; expense_date: string; amount: number; method: string; description: string | null; payee: string | null; status: string;
  created_by: string | null; created_at: string; cancel_reason: string | null; category_id: string;
};

export default async function ExpensesPage({ searchParams }: { searchParams: Promise<{ ay?: string; kategori?: string }> }) {
  const ctx = await requirePermission("expenses");
  const sp = await searchParams;
  const isAdmin = ctx.role === "yonetici";
  const today = todayISO();
  const ym = parseMonth(sp.ay, today);
  const { from, to } = isAdmin ? monthBounds(ym) : { from: addDaysISO(today, -60), to: today };
  const supabase = await supabaseServer();

  let q = supabase.from("expenses")
    .select("id, expense_date, amount, method, description, payee, status, created_by, created_at, cancel_reason, category_id")
    .eq("business_id", ctx.businessId).gte("expense_date", from).lte("expense_date", to)
    .order("expense_date", { ascending: false }).order("created_at", { ascending: false }).limit(500);
  if (isAdmin && sp.kategori) q = q.eq("category_id", sp.kategori);
  const [{ data: cats }, { data: ex, error }, { data: members }, rep] = await Promise.all([
    supabase.from("expense_categories").select("id, name, code, restricted").eq("business_id", ctx.businessId).eq("active", true).order("sort"),
    q,
    isAdmin ? supabase.from("memberships").select("user_id, display_name").eq("business_id", ctx.businessId) : Promise.resolve({ data: [] }),
    isAdmin ? supabase.rpc("profit_report", { p_business: ctx.businessId, p_from: from, p_to: to, p_grain: "ay" }) : Promise.resolve({ data: null }),
  ]);
  const categories = (cats ?? []) as ExpenseCategory[];
  const catName = new Map(categories.map((c) => [c.id, c.name]));
  const rows = (ex ?? []) as Row[];
  const names = new Map(((members ?? []) as { user_id: string; display_name: string }[]).map((m) => [m.user_id, m.display_name]));
  const period = isAdmin && rep.data ? (((rep.data as { periods: Record<string, unknown>[] }).periods ?? [])[0] ?? null) : null;
  const p = period ? normalizePeriod(period) : null;

  const columns = [
    { key: "d", label: "Tarih", render: (r: Row) => formatDate(r.expense_date) },
    { key: "c", label: "Kalem", render: (r: Row) => (
      <span className="flex flex-wrap items-center gap-1">
        {catName.get(r.category_id) ?? "Gider"}
        {r.status === "iptal" ? <Badge tone="danger">İptal</Badge> : null}
      </span>
    ) },
    { key: "a", label: "Tutar", align: "right" as const, render: (r: Row) => <span className={r.status === "iptal" ? "text-muted line-through" : "font-medium"}>{formatTRY(r.amount)}</span> },
    { key: "x", label: "Açıklama", render: (r: Row) => [r.payee, r.description, r.status === "iptal" && r.cancel_reason ? `İptal: ${r.cancel_reason}` : null].filter(Boolean).join(" · ") || "—" },
    { key: "m", label: "Ödeme", hideOnMobile: true, render: (r: Row) => (r.method === "kasa" ? "Kasa (nakit)" : "Banka / kart") },
    ...(isAdmin ? [{ key: "u", label: "Giren", hideOnMobile: true, render: (r: Row) => (r.created_by ? names.get(r.created_by) ?? "—" : "—") }] : []),
    { key: "act", label: "", interactive: true, align: "right" as const, render: (r: Row) =>
      r.status === "gecerli" && (isAdmin || (r.created_by === ctx.userId && formatDate(r.created_at) === formatDate(today)))
        ? <ExpenseCancel id={r.id} /> : null },
  ];

  if (!isAdmin) {
    return (
      <div>
        <PageHeader title="Giderler" subtitle="Yaptığınız şirket harcamalarını buraya girin" actions={<ExpenseForm categories={categories} isAdmin={false} />} />
        {error ? <Alert>{error.message}</Alert> : null}
        <Card className="mb-3 text-sm text-muted">
          Yakıt, araç, elektrik/su, sarf ve temizlik malzemesi gibi harcamaları fiş tarihiyle girin. Burada yalnızca sizin girdiğiniz son 60 günün giderleri görünür.
          Yanlış girdiğiniz bir gideri aynı gün iptal edebilirsiniz; sonrası için yöneticiye haber verin.
        </Card>
        <h2 className="mb-2 text-sm font-semibold text-muted">Girdiğim giderler</h2>
        <DataTable rows={rows} rowKey={(r) => r.id} mobileTitle={(r) => catName.get(r.category_id) ?? "Gider"} columns={columns} empty="Henüz gider girmediniz" />
      </div>
    );
  }

  const active = rows.filter((r) => r.status === "gecerli");
  const restrictedIds = new Set(categories.filter((c) => c.restricted).map((c) => c.id));
  const fixedTotal = active.filter((r) => restrictedIds.has(r.category_id)).reduce((s, r) => s + Number(r.amount), 0);
  const href = (m: string) => `/giderler?ay=${m}`;

  return (
    <div className="space-y-4">
      <PageHeader title="Giderler" subtitle={monthLabel(ym)}
        actions={
          <span className="flex flex-wrap gap-2">
            <Link href={`/raporlar/gelir-gider?ay=${ym}`} className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">Gelir-gider raporu</Link>
            <ExpenseForm categories={categories} isAdmin />
          </span>
        } />
      <div className="flex items-center gap-2">
        <Link href={href(addMonths(ym, -1))} className="inline-flex h-9 w-9 items-center justify-center rounded-xl border border-border bg-surface" aria-label="Önceki ay"><ChevronLeft className="h-4 w-4" /></Link>
        <span className="min-w-28 text-center font-medium">{monthLabel(ym)}</span>
        {ym < today.slice(0, 7) ? (
          <Link href={href(addMonths(ym, 1))} className="inline-flex h-9 w-9 items-center justify-center rounded-xl border border-border bg-surface" aria-label="Sonraki ay"><ChevronRight className="h-4 w-4" /></Link>
        ) : null}
      </div>
      {error ? <Alert>{error.message}</Alert> : null}
      {p ? (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Gelir" value={formatTRY(p.income)} hint={`Faturalı ${formatTRY(p.income_invoiced)}`} />
          <Stat label="Mal alımı (mal kabul)" value={formatTRY(p.purchases)} hint={`${p.purchase_count} belge`} />
          <Stat label="Giderler" value={formatTRY(p.expenses)} hint={`Maaş, kira, vergi ${formatTRY(fixedTotal)}`} />
          <Stat label="Net kâr" value={formatTRY(p.net_profit)} tone={p.net_profit < 0 ? "danger" : "ok"} hint={`Brüt ${formatTRY(p.gross_profit)}`} />
        </div>
      ) : null}
      {p && Object.keys(p.expense_categories).length ? (
        <Card>
          <div className="mb-2 text-sm font-semibold">Kalemlere göre</div>
          <div className="flex flex-wrap gap-2">
            <Link href={href(ym)} className={`rounded-full px-3 py-1.5 text-sm ${!sp.kategori ? "bg-brand text-white" : "bg-surface-2"}`}>Tümü · {formatTRY(p.expenses)}</Link>
            {categories.filter((c) => p.expense_categories[c.name]).map((c) => (
              <Link key={c.id} href={`${href(ym)}&kategori=${c.id}`} className={`rounded-full px-3 py-1.5 text-sm ${sp.kategori === c.id ? "bg-brand text-white" : "bg-surface-2"}`}>
                {c.name} · {formatTRY(p.expense_categories[c.name])}
              </Link>
            ))}
          </div>
        </Card>
      ) : null}
      <DataTable rows={rows} rowKey={(r) => r.id} mobileTitle={(r) => catName.get(r.category_id) ?? "Gider"} columns={columns}
        empty={`${monthLabel(ym)} için gider girilmemiş`} />
      <p className="text-xs text-muted">Mal kabulde girilen alış faturaları ayrıca “Mal alımı” olarak gidere sayılır; buraya tekrar girmeyin. Tutarlar KDV dahildir.</p>
    </div>
  );
}
