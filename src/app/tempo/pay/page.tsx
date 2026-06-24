import { Suspense } from "react";
import { TempoPayForm } from "./form";

export default function TempoPayPage() {
  return (
    <Suspense fallback={null}>
      <TempoPayForm />
    </Suspense>
  );
}
