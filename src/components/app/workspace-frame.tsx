"use client";

import type { ReactNode } from "react";
import Link from "next/link";
import { useEffect, useState } from "react";
import type { UserRole } from "@/lib/auth/roles";
import { Sidebar } from "@/components/app/sidebar";
import styles from "@/components/app/workspace-frame.module.css";

export function WorkspaceFrame({
  role,
  name,
  children,
}: {
  role: UserRole;
  name: string | null;
  children: ReactNode;
}) {
  const [drawerOpen, setDrawerOpen] = useState(false);

  useEffect(() => {
    if (!drawerOpen) return;

    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setDrawerOpen(false);
    };
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    window.addEventListener("keydown", closeOnEscape);

    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [drawerOpen]);

  const closeDrawer = () => setDrawerOpen(false);

  return (
    <div className={styles.workspaceFrame}>
      <Sidebar drawerOpen={drawerOpen} onClose={closeDrawer} role={role} name={name} />
      {drawerOpen && (
        <button
          type="button"
          className={styles.backdrop}
          aria-label="Tutup menu navigasi"
          onClick={closeDrawer}
        />
      )}
      <div className="workspace-main">
        <header className={`mobile-header ${styles.mobileHeader}`}>
          <Link className="brand" href="/dashboard" aria-label="Quena Mart, Dashboard">
            <span className="brand-mark" aria-hidden="true">Q</span>
            <span>quena<span className="brand-light">mart</span></span>
          </Link>
          <button
            type="button"
            className={styles.menuButton}
            aria-label={drawerOpen ? "Tutup menu navigasi" : "Buka menu navigasi"}
            aria-expanded={drawerOpen}
            aria-controls="workspace-sidebar"
            onClick={() => setDrawerOpen((open) => !open)}
          >
            {drawerOpen ? (
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18" /></svg>
            ) : (
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
            )}
          </button>
        </header>
        {children}
      </div>
    </div>
  );
}
