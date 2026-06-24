import { Suspense } from "react";
import { NewTransactionForm } from "./form";

export default function NewTransactionPage() {
  return (
    <Suspense fallback={null}>
      <NewTransactionForm />
    </Suspense>
  );
}
