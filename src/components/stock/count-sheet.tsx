"use client";
import { useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Input } from "@/components/ui/field";
import { useRpc } from "@/lib/use-action";
import { searchKey } from "@/lib/catalog";
import { formatNumber } from "@/lib/format";

export interface CountLine {
  productId: string; name: string; code: string; baseUnit: string;
  units: { id: string; name: string; factor: number }[];
  snapshot: number; counted: number | null; diff: number | null;
}

/** Birim karışık giriş: ör. 3 koli + 5 şişe → temel birime çevrilir. */
export function CountSheet({ countId, status, lines, canApprove }: { countId: string; status: string; lines: CountLine[]; canApprove: boolean }) {
  const { call, busy } = useRpc();
  const [q, setQ] = useState("");
  const [parts, setParts] = useState<Record<string, Record<string, string>>>({});
  const [dirty, setDirty] = useState<Set<string>>(new Set());
  const open = status === "acik";

  const total = (l: CountLine): number | null => {
    const p = parts[l.productId];
    if (!p) return l.counted;
    const vals = Object.entries(p).filter(([, v]) => v !== "");
    if (vals.length === 0) return null;
    return vals.reduce((s, [k, v]) => s + (parseInt(v, 10) || 0) * (k === "base" ? 1 : l.units.find((u) => u.id === k)?.factor ?? 1), 0);
  };
  const setPart = (pid: string, key: string, v: string) => {
    setParts((x) => ({ ...x, [pid]: { ...(x[pid] ?? {}), [key]: v.replace(/\D/g, "") } }));
    setDirty((d) => new Set(d).add(pid));
  };

  const shown = useMemo(() => {
    const k = searchKey(q.trim());
    return lines.filter((l) => !k || searchKey(`${l.name} ${l.code}`).includes(k));
  }, [lines, q]);
  const countedN = lines.filter((l) => total(l) !== null).length;

  async function save() {
    const payload = [...dirty].map((pid) => ({ product_id: pid, counted_qty: total(lines.find((l) => l.productId === pid)!) }));
    if (payload.length === 0) return;
    const ok = await call("save_stock_count_lines", { p_count: countId, p_lines: payload }, { success: "Sayım kaydedildi" });
    if (ok) setDirty(new Set());
  }

  return (
    <div className="space-y-3">
      {!open ? <Alert tone="neutral">Bu sayım kapanmış.</Alert> : <Alert tone="brand">{countedN} / {lines.length} ürün sayıldı. Boş bırakılan ürünlerin stoğu değişmez.</Alert>}
      <Input placeholder="Ürün ara" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="space-y-2">
        {shown.map((l) => {
          const t = total(l);
          return (
            <Card key={l.productId} className="p-3">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="font-medium">{l.name}</div>
                  <div className="text-xs text-muted">Sayım başında sistem: {formatNumber(l.snapshot)} {l.baseUnit.toLocaleLowerCase("tr-TR")}</div>
                </div>
                <div className="text-right">
                  {t !== null ? <div className="num font-semibold">{formatNumber(t)}</div> : <Badge>Sayılmadı</Badge>}
                  {l.diff !== null ? <div className={`num text-xs ${l.diff < 0 ? "text-danger" : l.diff > 0 ? "text-ok" : "text-muted"}`}>Fark {l.diff > 0 ? "+" : ""}{l.diff}</div> : null}
                </div>
              </div>
              {open ? (
                <div className="mt-2 flex flex-wrap gap-2">
                  {l.units.map((u) => (
                    <label key={u.id} className="flex items-center gap-1 text-sm">
                      <Input className="h-10 w-20" inputMode="numeric" value={parts[l.productId]?.[u.id] ?? ""} onChange={(e) => setPart(l.productId, u.id, e.target.value)} />
                      {u.name}
                    </label>
                  ))}
                  <label className="flex items-center gap-1 text-sm">
                    <Input className="h-10 w-20" inputMode="numeric" value={parts[l.productId]?.base ?? (parts[l.productId] ? "" : l.counted?.toString() ?? "")} onChange={(e) => setPart(l.productId, "base", e.target.value)} />
                    {l.baseUnit}
                  </label>
                </div>
              ) : null}
            </Card>
          );
        })}
      </div>
      {open ? (
        <div className="safe-bottom sticky bottom-20 flex flex-wrap gap-2 rounded-2xl bg-bg py-2 md:bottom-0">
          <Button className="flex-1" loading={busy} disabled={dirty.size === 0} onClick={save}>Kaydet ({dirty.size})</Button>
          {canApprove ? (
            <>
              <Button variant="ok" loading={busy} disabled={dirty.size > 0 || countedN === 0}
                onClick={() => confirm("Sayım farkları stoğa işlenecek ve sayım kilitlenecek. Onaylıyor musunuz?") && call("approve_stock_count", { p_count: countId }, { success: "Sayım onaylandı" })}>
                Onayla ve stoğa işle
              </Button>
              <Button variant="ghost" onClick={() => confirm("Sayım iptal edilsin mi?") && call("cancel_stock_count", { p_count: countId }, { success: "Sayım iptal edildi" })}>İptal</Button>
            </>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
