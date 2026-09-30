"use client";
import { useEffect, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { Search } from "lucide-react";
import { Input } from "./field";

export function SearchBox({ placeholder, param = "q" }: { placeholder: string; param?: string }) {
  const router = useRouter();
  const path = usePathname();
  const params = useSearchParams();
  const [v, setV] = useState(params.get(param) ?? "");
  useEffect(() => {
    const t = setTimeout(() => {
      const p = new URLSearchParams(params.toString());
      if (v.trim()) p.set(param, v.trim());
      else p.delete(param);
      const next = `${path}?${p.toString()}`;
      if (next !== `${path}?${params.toString()}`) router.replace(next);
    }, 300);
    return () => clearTimeout(t);
  }, [v, param, path, params, router]);
  return (
    <div className="relative mb-4">
      <Search className="pointer-events-none absolute top-3 left-3 h-5 w-5 text-muted" />
      <Input value={v} onChange={(e) => setV(e.target.value)} placeholder={placeholder} className="pl-10" />
    </div>
  );
}
