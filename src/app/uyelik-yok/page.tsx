import { Card } from "@/components/ui/card";

export default function NoMembership() {
  return (
    <main className="flex min-h-dvh items-center justify-center p-4">
      <Card className="max-w-sm p-6 text-center">
        <h1 className="mb-2 text-lg font-semibold">Hesabınız bir işletmeye bağlı değil</h1>
        <p className="text-sm text-muted">Yöneticinizden sizi ALKASU&apos;ya eklemesini isteyin. Hesabınız pasife alınmış da olabilir.</p>
        <a href="/giris" className="mt-4 inline-block text-sm text-brand">Giriş sayfasına dön</a>
      </Card>
    </main>
  );
}
