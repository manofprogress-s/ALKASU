"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { useAppContext } from "@/components/shell/context";
import { useRpc } from "@/lib/use-action";

/** Sayım onaylayanlar (T-04/6, D-095): işaretli yöneticilerin hepsi onaylayınca sayım stoğa işlenir. Hiçbiri işaretli değilse tüm yöneticiler (en fazla 2 onay). */
export function CountApprovers({ admins, initial }: { admins: { user_id: string; name: string }[]; initial: string[] }) {
  const ctx = useAppContext();
  const { call, busy } = useRpc();
  const [sel, setSel] = useState<Set<string>>(new Set(initial));
  const n = sel.size || Math.min(2, admins.length);
  return (
    <Card className="space-y-3">
      <div>
        <h2 className="font-semibold">Sayım onaylayanlar</h2>
        <p className="text-sm text-muted">Sayım, işaretli yöneticilerin hepsi onaylayınca stoğa işlenir. Şu an gereken onay: <b>{n}</b>.</p>
      </div>
      <div className="flex flex-wrap gap-3">
        {admins.map((a) => (
          <label key={a.user_id} className="flex items-center gap-2">
            <input type="checkbox" className="h-5 w-5" checked={sel.has(a.user_id)}
              onChange={(e) => setSel((x) => { const s = new Set(x); if (e.target.checked) s.add(a.user_id); else s.delete(a.user_id); return s; })} />
            {a.name}
          </label>
        ))}
      </div>
      {!sel.size ? <p className="text-xs text-muted">Hiçbiri seçili değilse tüm yöneticiler onaylayabilir (en fazla 2 onay gerekir).</p> : null}
      <Button loading={busy} onClick={() => call("set_count_approvers", { p_business: ctx.businessId, p_users: [...sel] }, { success: "Sayım onaylayanlar kaydedildi" })}>Kaydet</Button>
    </Card>
  );
}
