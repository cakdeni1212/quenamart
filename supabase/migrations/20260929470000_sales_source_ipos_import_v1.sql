-- Daily iPos sales import source identity. Add the enum value in its own
-- migration so later migration statements can safely use it on PostgreSQL 15.
ALTER TYPE public.pos_sale_source ADD VALUE IF NOT EXISTS 'IPOS_IMPORT';
