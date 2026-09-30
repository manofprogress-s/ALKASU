"use client";
import { useMemo, useState } from "react";
import { Dialog } from "@/components/ui/dialog";
import { Input } from "@/components/ui/field";
import { searchKey } from "@/lib/catalog";
import type { LiteProduct } from "@/lib/products-lite";

export function ProductSelect({ open, onClose, products, onPick, filter }: {
  open: boolean;
  onClose: () => void;
  products: LiteProduct[];
  onPick: (p: LiteProduct) => void;
  filter?: (p: LiteProduct) => boolean;
}) {
  const [q, setQ] = useState("");
  const list = useMemo(() => {
    const k = searchKey(q.trim());
    return products.filter((p) => (!filter || filter(p)) && (!k || searchKey(`${p.name} ${p.code}`).includes(k))).slice(0, 80);
  }, [products, q, filter]);
  return (
    <Dialog open={open} onClose={onClose} title="Ürün seç">
      <Input autoFocus placeholder="Ürün adı veya kodu" value={q} onChange={(e) => setQ(e.target.value)} className="mb-3" />
      <ul className="divide-y divide-border">
        {list.map((p) => (
          <li key={p.id}>
            <button className="w-full py-3 text-left" onClick={() => { onPick(p); setQ(""); }}>
              <span className="font-medium">{p.name}</span>
              <span className="ml-2 text-xs text-muted">{p.code}</span>
            </button>
          </li>
        ))}
      </ul>
    </Dialog>
  );
}
