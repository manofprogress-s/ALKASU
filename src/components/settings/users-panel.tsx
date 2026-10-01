"use client";
import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { KeyRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, Badge, Card } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { useToast } from "@/components/ui/toast";
import { useRpc } from "@/lib/use-action";
import { ROLE_LABELS, ROLES, type Role } from "@/lib/roles";
import { createUser, resetUserPassword } from "@/app/(app)/ayarlar/actions";

export interface MemberRow {
  id: string;
  user_id: string;
  role: Role;
  display_name: string;
  active: boolean;
  username: string | null;
  customer_id: string | null;
  must_change_password: boolean;
}

export interface DealerOption {
  id: string;
  name: string;
}

export function UsersPanel({ members, me, dealers }: { members: MemberRow[]; me: string; dealers: DealerOption[] }) {
  const router = useRouter();
  const toast = useToast();
  const { call } = useRpc();
  const [login, setLogin] = useState("");
  const [name, setName] = useState("");
  const [role, setRole] = useState<Role>("satis");
  const [customerId, setCustomerId] = useState("");
  const [password, setPassword] = useState("");
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [resetFor, setResetFor] = useState<MemberRow | null>(null);
  const [resetPw, setResetPw] = useState("");
  const [resetError, setResetError] = useState<string | null>(null);
  const dealerName = (id: string | null) => dealers.find((d) => d.id === id)?.name ?? "";

  function changeRole(m: MemberRow, r: Role) {
    let cust = m.customer_id;
    if (r === "bayi" && !cust) {
      if (dealers.length === 0) {
        toast("Önce Müşteriler bölümünde kanalı 'Bayi' olan bir müşteri kartı oluşturun.", "danger");
        return;
      }
      cust = dealers[0]!.id;
    }
    void call("update_member", { p_membership: m.id, p_role: r, p_name: m.display_name, p_active: m.active, p_customer: r === "bayi" ? cust : null }, { success: "Rol güncellendi" });
  }

  return (
    <Card className="space-y-4">
      <h2 className="font-semibold">Kullanıcılar</h2>
      <ul className="divide-y divide-border">
        {members.map((m) => (
          <li key={m.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
            <span className="min-w-0">
              <span className="font-medium">{m.display_name}</span>{" "}
              {m.user_id === me ? <Badge tone="brand">Siz</Badge> : null} {!m.active ? <Badge>Pasif</Badge> : null}{" "}
              {m.must_change_password ? <Badge tone="warn">Şifre değiştirecek</Badge> : null}
              <span className="block text-xs text-muted">
                {m.username ? `Kullanıcı adı: ${m.username}` : "E-posta ile giriş"}
                {m.role === "bayi" && m.customer_id ? ` · Bayi: ${dealerName(m.customer_id)}` : ""}
              </span>
            </span>
            <span className="flex flex-wrap items-center gap-2">
              <Select className="h-9 w-52" value={m.role} disabled={m.user_id === me} onChange={(e) => changeRole(m, e.target.value as Role)}>
                {ROLES.map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}
              </Select>
              {m.role === "bayi" ? (
                <Select className="h-9 w-44" value={m.customer_id ?? ""} onChange={(e) => call("update_member", { p_membership: m.id, p_role: m.role, p_name: m.display_name, p_active: m.active, p_customer: e.target.value }, { success: "Bayi kartı güncellendi" })}>
                  {dealers.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
                </Select>
              ) : null}
              {m.user_id !== me ? (
                <>
                  <Button size="sm" variant="ghost" onClick={() => { setResetFor(m); setResetPw(""); setResetError(null); }}>
                    <KeyRound className="h-4 w-4" /> Şifre ver
                  </Button>
                  <Button size="sm" variant="ghost" onClick={() => call("update_member", { p_membership: m.id, p_role: m.role, p_name: m.display_name, p_active: !m.active, p_customer: m.customer_id }, { success: m.active ? "Kullanıcı pasife alındı" : "Kullanıcı aktifleştirildi" })}>
                    {m.active ? "Pasife al" : "Aktifleştir"}
                  </Button>
                </>
              ) : null}
            </span>
          </li>
        ))}
      </ul>

      <div className="space-y-3 rounded-xl bg-surface-2 p-3">
        <h3 className="text-sm font-semibold">Yeni kullanıcı</h3>
        <div className="grid gap-2 md:grid-cols-3">
          <Field label="Kullanıcı adı" hint="Örn. HTopal. E-posta da yazılabilir.">
            <Input autoCapitalize="none" autoCorrect="off" spellCheck={false} value={login} onChange={(e) => setLogin(e.target.value)} />
          </Field>
          <Field label="Ad soyad"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
          <Field label="Rol">
            <Select value={role} onChange={(e) => setRole(e.target.value as Role)}>
              {ROLES.map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}
            </Select>
          </Field>
          {role === "bayi" ? (
            <Field label="Bayi müşteri kartı" hint={dealers.length === 0 ? "Önce kanalı 'Bayi' olan bir müşteri oluşturun" : "Bayi yalnızca bu kartın verisini görür"}>
              <Select value={customerId} onChange={(e) => setCustomerId(e.target.value)}>
                <option value="">Seçin…</option>
                {dealers.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </Select>
            </Field>
          ) : null}
          <Field label="Geçici şifre" hint="En az 8 karakter. Kullanıcı ilk girişte kendi şifresini belirler.">
            <Input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
          <div className="flex items-end">
            <Button className="w-full" loading={pending} onClick={() => start(async () => {
              setError(null);
              const r = await createUser({ login, name, role, customerId: role === "bayi" ? customerId || null : null, password });
              if (!r.ok) return setError(r.message);
              toast(r.message, "ok");
              setLogin(""); setName(""); setPassword(""); setCustomerId("");
              router.refresh();
            })}>Kullanıcı oluştur</Button>
          </div>
        </div>
        {error ? <Alert>{error}</Alert> : null}
      </div>

      <Dialog
        open={!!resetFor}
        onClose={() => setResetFor(null)}
        title={`Geçici şifre: ${resetFor?.display_name ?? ""}`}
        footer={
          <Button className="w-full" loading={pending} onClick={() => start(async () => {
            if (!resetFor) return;
            setResetError(null);
            const r = await resetUserPassword({ membershipId: resetFor.id, password: resetPw });
            if (!r.ok) return setResetError(r.message);
            toast(r.message, "ok");
            setResetFor(null);
            router.refresh();
          })}>Kaydet</Button>
        }
      >
        <div className="space-y-3">
          <Field label="Yeni geçici şifre" hint="Kullanıcı bu şifreyle girip hemen kendi şifresini belirleyecek.">
            <Input type="password" autoComplete="new-password" value={resetPw} onChange={(e) => setResetPw(e.target.value)} />
          </Field>
          {resetError ? <Alert>{resetError}</Alert> : null}
        </div>
      </Dialog>
    </Card>
  );
}
