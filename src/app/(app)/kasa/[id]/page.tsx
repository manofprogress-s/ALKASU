import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { Card, PageHeader, Stat } from "@/components/ui/card";
import { formatDateTime, formatTRY } from "@/lib/format";
import { CASH_LABELS } from "@/lib/labels";

export default async function ClosedSession({ params }: { params: Promise<{ id: string }> }) {
  const ctx = await requirePermission("cash");
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc("cash_session_summary", { p_business: ctx.businessId, p_session: id });
  if (error || !data) notFound();
  const s = data as Record<string, unknown> & { movements: Record<string, number> };
  return (
    <div className="space-y-4">
      <PageHeader title={`Kasa günü #${s.no}`} subtitle={`${formatDateTime(s.opened_at as string)} – ${formatDateTime(s.closed_at as string)}`} />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Beklenen" value={formatTRY(s.expected_cash as number)} />
        <Stat label="Sayılan" value={formatTRY(s.counted_cash as number)} />
        <Stat label="Fark" value={formatTRY(s.cash_diff as number)} tone={Number(s.cash_diff) !== 0 ? "danger" : "ok"} hint={(s.diff_note as string) ?? undefined} />
        <Stat label="Devreden" value={formatTRY(s.carry_over as number)} />
        <Stat label="POS (sistem / slip)" value={`${formatTRY(s.pos_expected as number)}`} hint={`Slip ${formatTRY(s.pos_slip as number)} · fark ${formatTRY(s.pos_diff as number)}`} />
        <Stat label="Satış" value={formatTRY(s.sales_total as number)} hint={`${s.sales_count} fiş`} />
      </div>
      <Card>
        <h2 className="mb-2 font-semibold">Nakit hareket özeti</h2>
        <ul className="space-y-1 text-sm">
          <li className="flex justify-between"><span>Açılış</span><span className="num">{formatTRY(s.opening_cash as number)}</span></li>
          {Object.entries(s.movements).map(([k, v]) => (
            <li key={k} className="flex justify-between"><span>{CASH_LABELS[k] ?? k}</span><span className="num">{formatTRY(v)}</span></li>
          ))}
        </ul>
      </Card>
    </div>
  );
}
