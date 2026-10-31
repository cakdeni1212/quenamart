import type { ReactNode } from "react";
import styles from "./page-header.module.css";

export function PageHeader({ eyebrow, title, description, actions, className }: {
  eyebrow?: string;
  title: string;
  description?: string;
  actions?: ReactNode;
  className?: string;
}) {
  return <header className={[styles.header, className].filter(Boolean).join(" ")}>
    <div className={styles.copy}>
      {eyebrow ? <div className="eyebrow">{eyebrow}</div> : null}
      <h1>{title}</h1>
      {description ? <p>{description}</p> : null}
    </div>
    {actions ? <div className={styles.actions}>{actions}</div> : null}
  </header>;
}
