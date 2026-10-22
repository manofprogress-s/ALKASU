import Link from "next/link";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { formatTRY } from "@/lib/format";
import { CHART_COLORS, niceMax, shortTRY } from "@/lib/profit";

export interface ProfitBar {
  key: string;
  label: string;
  href?: string;
  active?: boolean;
  green: number;   // faturalı gelir
  orange: number;  // faturasız gelir (teslimat)
  red: number;     // gider (mal alımı + işletme gideri)
  net: number;
}

/** Gelir (yeşil + turuncu yığılı) ve gider (kırmızı) çubukları; altta net kâr. */
export function ProfitChart({ bars, height = 180 }: { bars: ProfitBar[]; height?: number }) {
  const max = niceMax(Math.max(0, ...bars.map((b) => Math.max(b.green + b.orange, b.red))));
  const pct = (v: number) => `${Math.max(0, (v / max) * 100)}%`;
  return (
    <div>
      <div className="mb-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted">
        <Legend color={CHART_COLORS.invoiced}>Gelir · faturası kesildi</Legend>
        <Legend color={CHART_COLORS.uninvoiced}>Gelir · fatura bekliyor</Legend>
        <Legend color={CHART_COLORS.expense}>Gider (mal alımı + giderler)</Legend>
      </div>
      <div className="overflow-x-auto pb-1">
        <div className="flex min-w-full gap-1" style={{ minWidth: `${bars.length * 48}px` }}>
          <div className="flex shrink-0 flex-col justify-between pr-1 text-right text-[10px] text-muted" style={{ height }}>
            <span>{shortTRY(max)}</span><span>{shortTRY(max / 2)}</span><span>0</span>
          </div>
          {bars.map((b) => {
            const inner = (
              <>
                <div className="relative flex items-end justify-center gap-0.5 border-b border-border" style={{ height }}>
                  <div className="pointer-events-none absolute inset-x-0 top-1/2 border-t border-dashed border-border" />
                  <div className="flex w-1/3 max-w-5 flex-col justify-end" style={{ height: "100%" }}
                    title={`Gelir ${formatTRY(b.green + b.orange)} · faturalı ${formatTRY(b.green)} · fatura bekliyor ${formatTRY(b.orange)}`}>
                    <div className="rounded-t-sm" style={{ height: pct(b.orange), background: CHART_COLORS.uninvoiced }} />
                    <div className={cn(b.orange > 0 ? "" : "rounded-t-sm")} style={{ height: pct(b.green), background: CHART_COLORS.invoiced }} />
                  </div>
                  <div className="w-1/3 max-w-5 rounded-t-sm" style={{ height: pct(b.red), background: CHART_COLORS.expense }} title={`Gider ${formatTRY(b.red)}`} />
                </div>
                <div className={cn("mt-1 truncate text-center text-[11px]", b.active ? "font-semibold text-brand" : "text-muted")}>{b.label}</div>
                <div className={cn("truncate text-center text-[11px] font-medium tabular-nums", b.net < 0 ? "text-danger" : "text-ok")} title={`Net kâr ${formatTRY(b.net)}`}>
                  {b.net === 0 ? "–" : shortTRY(b.net)}
                </div>
              </>
            );
            const cls = cn("min-w-11 flex-1 rounded-lg px-0.5 pt-1", b.active && "bg-brand-soft");
            return b.href ? (
              <Link key={b.key} href={b.href} scroll={false} className={cn(cls, "hover:bg-surface-2")} aria-label={`${b.label}: ayrıntı`}>{inner}</Link>
            ) : (
              <div key={b.key} className={cls}>{inner}</div>
            );
          })}
        </div>
      </div>
      <p className="mt-1 text-[11px] text-muted">Çubukların altındaki rakam net kârdır (yeşil kâr, kırmızı zarar).</p>
    </div>
  );
}

function Legend({ color, children }: { color: string; children: ReactNode }) {
  return <span className="inline-flex items-center gap-1.5"><span className="h-2.5 w-2.5 rounded-sm" style={{ background: color }} />{children}</span>;
}
