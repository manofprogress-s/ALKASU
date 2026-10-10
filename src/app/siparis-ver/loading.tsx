import { GridSkeleton } from "@/components/ui/skeleton";

export default function Loading() {
  return <main className="mx-auto max-w-2xl p-4"><GridSkeleton items={6} /></main>;
}
