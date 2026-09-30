"use client";
import { createContext, useContext, type ReactNode } from "react";
import type { Role } from "@/lib/roles";

export interface ClientContext {
  userId: string;
  businessId: string;
  businessName: string;
  locationId: string;
  role: Role;
  displayName: string;
}

const Ctx = createContext<ClientContext | null>(null);

export function ContextProvider({ value, children }: { value: ClientContext; children: ReactNode }) {
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAppContext(): ClientContext {
  const v = useContext(Ctx);
  if (!v) throw new Error("ContextProvider eksik");
  return v;
}
