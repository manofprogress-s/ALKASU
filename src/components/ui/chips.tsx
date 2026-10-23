import Link from "next/link";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

/** Filtre / sekme düğmesi görünümü (tek yerde): seçili = mavi, uyarı = turuncu */
export function chipClass(active: boolean, tone: "brand" | "warn" = "brand"): string {
  return cn("shrink-0 rounded-full px-3 py-1.5 text-sm", active ? (tone === "warn" ? "bg-warn text-white" : "bg-brand text-white") : "bg-surface-2");
}

/** Bağlantı olarak filtre düğmesi */
export function Chip({ href, active = false, tone, children }: { href: string; active?: boolean; tone?: "brand" | "warn"; children: ReactNode }) {
  return <Link href={href} className={chipClass(active, tone)} aria-current={active ? "page" : undefined}>{children}</Link>;
}

/** Düğme sırası: mobilde yatay kayar (scroll), masaüstünde ya kayar ya da alt satıra geçer */
export function ChipBar({ children, wrap = false, label, className }: { children: ReactNode; wrap?: boolean; label?: string; className?: string }) {
  return (
    <nav aria-label={label}
      className={cn("no-print flex gap-2", wrap ? "flex-wrap" : "-mx-3 overflow-x-auto px-3 pb-1 [scrollbar-width:none]", className)}>
      {children}
    </nav>
  );
}

/** Sayı rozeti (düğme içinde) */
export function ChipCount({ n }: { n: number | string }) {
  return <span className="num opacity-75"> {n}</span>;
}
