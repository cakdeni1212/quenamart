# Reporting

Prepare future reporting for revenue, COGS, gross profit, operating expenses, net profit, inventory value/capital, transaction count, average basket, supplier outstanding debt, member analytics, historical period comparison, and charts. Define accounting and date-boundary semantics before calculating totals. HPP, capital, and profit are sensitive; restrict both UI and server/database reads by role. Dashboard currently uses empty placeholders and contains no invented business values.
# Transitional sales source roadmap

Until native Quena Mart POS is production-ready, iPos remains the transaction system of record. A future phase will support importing daily iPos sales reports into Quena Mart for sales analytics/reporting; that importer is not part of Phase 3A. Imported iPos sales and future native POS sales must eventually share a reporting model while retaining source identity, for example `IPOS_IMPORT` and `QUENA_POS`, so totals can be combined without losing provenance.
