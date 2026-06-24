import { Suspense } from "react";
import { TransactionsList } from "./list";

export default function TransactionsPage() {
  return (
    <Suspense fallback={null}>
      <TransactionsList />
    </Suspense>
  );
}
