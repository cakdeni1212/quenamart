import { prisma } from "./prisma";

let initialized = false;

export async function initDatabase() {
  if (initialized) return;
  initialized = true;

  try {
    await prisma.$executeRawUnsafe(`
      ALTER TABLE User ADD COLUMN role TEXT NOT NULL DEFAULT 'owner'
    `).catch(() => {});

    await prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS Cashier (
        id TEXT PRIMARY KEY,
        businessId TEXT NOT NULL,
        name TEXT NOT NULL,
        isActive INTEGER NOT NULL DEFAULT 1,
        createdAt TEXT NOT NULL DEFAULT (datetime('now')),
        updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE(businessId, name),
        FOREIGN KEY (businessId) REFERENCES Business(id) ON DELETE CASCADE
      )
    `);

    await prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS ExpenseDescription (
        id TEXT PRIMARY KEY,
        businessId TEXT NOT NULL,
        name TEXT NOT NULL,
        isActive INTEGER NOT NULL DEFAULT 1,
        sortOrder INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT NOT NULL DEFAULT (datetime('now')),
        updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE(businessId, name),
        FOREIGN KEY (businessId) REFERENCES Business(id) ON DELETE CASCADE
      )
    `);

    await prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS Supplier (
        id TEXT PRIMARY KEY,
        businessId TEXT NOT NULL,
        name TEXT NOT NULL,
        type TEXT NOT NULL DEFAULT 'supplier',
        phone TEXT,
        address TEXT,
        notes TEXT,
        isActive INTEGER NOT NULL DEFAULT 1,
        createdAt TEXT NOT NULL DEFAULT (datetime('now')),
        updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (businessId) REFERENCES Business(id) ON DELETE CASCADE
      )
    `);

    await prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS SupplierTempo (
        id TEXT PRIMARY KEY,
        businessId TEXT NOT NULL,
        supplierId TEXT NOT NULL,
        description TEXT NOT NULL,
        totalAmount REAL NOT NULL,
        paidAmount REAL NOT NULL DEFAULT 0,
        invoiceNo TEXT,
        dueDate TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        notes TEXT,
        receipt TEXT,
        createdAt TEXT NOT NULL DEFAULT (datetime('now')),
        updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (businessId) REFERENCES Business(id) ON DELETE CASCADE,
        FOREIGN KEY (supplierId) REFERENCES Supplier(id) ON DELETE CASCADE
      )
    `);

    await prisma.$executeRawUnsafe(`
      CREATE TABLE IF NOT EXISTS TempoPayment (
        id TEXT PRIMARY KEY,
        tempoId TEXT NOT NULL,
        amount REAL NOT NULL,
        paymentDate TEXT NOT NULL,
        notes TEXT,
        receipt TEXT,
        createdAt TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (tempoId) REFERENCES SupplierTempo(id) ON DELETE CASCADE
      )
    `);

    console.log("[DB] Auto-migration completed");
  } catch (e) {
    console.error("[DB] Auto-migration failed:", e);
    initialized = false;
  }
}
