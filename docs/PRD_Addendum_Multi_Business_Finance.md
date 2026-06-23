# PRD Addendum — Multi-Business Finance System

## Core Product Direction

The system should support *all* of the user's financial activities in one place:
- Minimarket business income and expenses
- Agriculture business expenses like labor, fertilizer, seeds, etc.
- Personal/family expenses
- Future new businesses with their own financial records

## Key Product Principle

This is not a single-business app. It is a *personal finance + multi-business finance hub*.

Each financial record must belong to exactly one of these scopes:
- Business
- Personal / Family

Inside Business scope, the user can create unlimited businesses such as:
- Minimarket
- Farming / Agriculture
- Future new business

## Answer to User Question

Yes, bro — *nanti kalau ada bisnis baru, tinggal create aja di dashboard*.

Recommended flow:
1. User clicks `Create Business`
2. Fill in:
   - business name
   - business type
   - optional description
   - start date
3. System creates a new business workspace
4. User can immediately start recording income and expenses under that business

## Important Design Rule

Do *not* mix records from different businesses into one bucket.

Example:
- Minimarket sales go to Business A
- Farm fertilizer expense goes to Business B
- Family shopping goes to Personal account

This makes reporting clean and scalable.

## Recommended Top-Level Modules

- Dashboard
- Businesses
- Personal / Family
- Transactions
- Categories
- Reports
- Users / Access

## Suggested Business Types

These are only labels, not hard-coded limits:
- Retail / Minimarket
- Agriculture / Farming
- F&B
- Trading
- Services
- Other

The user can still create any custom business name.
