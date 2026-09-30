"use client";
import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Field, Input, Select } from "@/components/ui/field";
import { useToast } from "@/components/ui/toast";
import { useRpc } from "@/lib/use-action";
import { ROLE_LABELS, type Role } from "@/lib/roles";
import { inviteUser } from "@/app/(app)/ayarlar/actions";

export function UsersPanel({ members, me }: { members: { id: string; user_id: string; role: string; display_name: string; active: boolean }[]; me: string }) {
  const router = useRouter();
  const toast = useToast();
  const { call } = useRpc();
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState<Role>("satis");
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);

  return (
    <Card className="space-y-4">
      <h2 className="font-semibold">Kullanıcılar</h2>
      <ul className="divide-y divide-border">
        {members.map((m) => (
          <li key={m.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
            <span>
              {m.display_name} {m.user_id === me ? <Badge tone="brand">Siz</Badge> : null} {!m.active ? <Badge>Pasif</Badge> : null}
            </span>
            <span className="flex items-center gap-2">
              <Select className="h-9 w-44" value={m.role} onChange={(e) => call("update_member", { p_membership: m.id, p_role: e.target.value, p_name: m.display_name, p_active: m.active }, { success: "Rol güncellendi" })}>
                {(Object.keys(ROLE_LABELS) as Role[]).map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}
              </Select>
              <Button size="sm" variant="ghost" onClick={() => call("update_member", { p_membership: m.id, p_role: m.role, p_name: m.display_name, p_active: !m.active }, { success: m.active ? "Kullanıcı pasife alındı" : "Kullanıcı aktifleştirildi" })}>
                {m.active ? "Pasife al" : "Aktifleştir"}
              </Button>
            </span>
          </li>
        ))}
      </ul>
      <div className="grid gap-2 rounded-xl bg-surface-2 p-3 md:grid-cols-4">
        <Field label="E-posta"><Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
        <Field label="Ad soyad"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
        <Field label="Rol"><Select value={role} onChange={(e) => setRole(e.target.value as Role)}>{(Object.keys(ROLE_LABELS) as Role[]).map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}</Select></Field>
        <div className="flex items-end">
          <Button className="w-full" loading={pending} onClick={() => start(async () => {
            setError(null);
            const r = await inviteUser({ email, name, role });
            if (!r.ok) return setError(r.message);
            toast(r.message, "ok");
            setEmail(""); setName("");
            router.refresh();
          })}>Davet et</Button>
        </div>
        {error ? <div className="md:col-span-4"><Alert>{error}</Alert></div> : null}
      </div>
    </Card>
  );
}
