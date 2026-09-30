"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/field";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";
import { parseAmount } from "@/lib/format";

export function SettingsPanel({ initial }: { initial: Record<string, number> }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [v, setV] = useState({
    max_discount_pct_satis: String(initial.max_discount_pct_satis ?? 5),
    cash_diff_tolerance: String(initial.cash_diff_tolerance ?? 50),
    critical_stock_days: String(initial.critical_stock_days ?? 7),
  });
  return (
    <Card className="space-y-3">
      <h2 className="font-semibold">İşletme ayarları</h2>
      <div className="grid gap-3 md:grid-cols-3">
        <Field label="Satış personeli en fazla indirim (%)"><Input inputMode="decimal" value={v.max_discount_pct_satis} onChange={(e) => setV({ ...v, max_discount_pct_satis: e.target.value })} /></Field>
        <Field label="Kasa farkı toleransı (₺)" hint="Aşılırsa açıklama zorunlu"><Input inputMode="decimal" value={v.cash_diff_tolerance} onChange={(e) => setV({ ...v, cash_diff_tolerance: e.target.value })} /></Field>
        <Field label="Kritik stok önerisi (gün)" hint="Ortalama günlük satış × gün"><Input inputMode="numeric" value={v.critical_stock_days} onChange={(e) => setV({ ...v, critical_stock_days: e.target.value })} /></Field>
      </div>
      <Button loading={busy} onClick={() => call("update_settings", { p_business: ctx.businessId, p: {
        max_discount_pct_satis: parseAmount(v.max_discount_pct_satis), cash_diff_tolerance: parseAmount(v.cash_diff_tolerance), critical_stock_days: parseInt(v.critical_stock_days, 10),
      } }, { success: "Ayarlar kaydedildi" })}>Kaydet</Button>
    </Card>
  );
}
