import Link from "next/link";
import type { ReactNode } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { cn } from "@/lib/cn";
import { addMonths, monthLabel } from "@/lib/profit";

const btn = "inline-flex h-9 w-9 items-center justify-center rounded-xl border border-border bg-surface";

/**
 * Ay seçici: ‹ Ekim 2026 ›. `max` ayından ileri gidilmez (varsayılan: sınırsız).
 * `href` her ay için bağlantıyı üretir; `children` sağda ek içerik (ör. "Bu ay" bağlantısı).
 */
export function MonthNav({ month, href, max, large, children }: {
  month: string; href: (ym: string) => string; max?: string; large?: boolean; children?: ReactNode;
}) {
  const next = addMonths(month, 1);
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Link href={href(addMonths(month, -1))} className={btn} aria-label="Önceki ay" scroll={false}><ChevronLeft className="h-4 w-4" /></Link>
      <span className={cn("min-w-28 text-center", large ? "text-lg font-semibold" : "font-medium")}>{monthLabel(month)}</span>
      {!max || next <= max ? (
        <Link href={href(next)} className={btn} aria-label="Sonraki ay" scroll={false}><ChevronRight className="h-4 w-4" /></Link>
      ) : null}
      {children}
    </div>
  );
}

/** Ay seçicinin küçük ok düğmesi (12 aylık pencere gibi özel gezinmeler için) */
export function MonthArrow({ href, dir, label }: { href: string; dir: "prev" | "next"; label: string }) {
  return (
    <Link href={href} className={btn} aria-label={label} scroll={false}>
      {dir === "prev" ? <ChevronLeft className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
    </Link>
  );
}
