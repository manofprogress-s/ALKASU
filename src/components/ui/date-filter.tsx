"use client";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { addDaysISO, todayISO } from "@/lib/format";
import { Input } from "./field";
import { Button } from "./button";

export function DateFilter({ from, to }: { from: string; to: string }) {
  const router = useRouter();
  const path = usePathname();
  const params = useSearchParams();
  const go = (f: string, t: string) => {
    const p = new URLSearchParams(params.toString());
    p.set("from", f);
    p.set("to", t);
    router.push(`${path}?${p.toString()}`);
  };
  const today = todayISO();
  const monthStart = `${today.slice(0, 8)}01`;
  return (
    <div className="no-print mb-4 flex flex-wrap items-end gap-2">
      <Button size="sm" variant={from === today && to === today ? "primary" : "secondary"} onClick={() => go(today, today)}>Bugün</Button>
      <Button size="sm" variant="secondary" onClick={() => go(addDaysISO(today, -1), addDaysISO(today, -1))}>Dün</Button>
      <Button size="sm" variant="secondary" onClick={() => go(addDaysISO(today, -6), today)}>7 gün</Button>
      <Button size="sm" variant="secondary" onClick={() => go(monthStart, today)}>Bu ay</Button>
      <Input type="date" className="h-9 w-auto" value={from} max={to} onChange={(e) => e.target.value && go(e.target.value, to)} aria-label="Başlangıç" />
      <Input type="date" className="h-9 w-auto" value={to} min={from} onChange={(e) => e.target.value && go(from, e.target.value)} aria-label="Bitiş" />
    </div>
  );
}
