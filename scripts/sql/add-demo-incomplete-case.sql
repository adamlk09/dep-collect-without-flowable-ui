-- ================================================================
-- Demo : dossier INCOMPLET (CASE-9013) - total_debt_amount absent -> la segmentation doit etre refusee
-- (controle qualite des donnees). Rejouable (NOT EXISTS). Retrait : remove-demo-cases.sql
-- ================================================================
INSERT INTO core.debtor (uuid, code, description, is_delete, is_statut, create_date_time, update_date_time,
    debtor_reference, full_name, first_name, last_name, client_type, status, risk_segment, external_reference,
    phone, email, city, address, creditor_id)
SELECT gen_random_uuid()::text, 'DEBTOR-9013', 'Demo dossier incomplet', false, true, now(), now(),
    'DEBTOR-9013', 'Rachid Benjelloun', 'Rachid', 'Benjelloun', 'INDIVIDUAL', 'ACTIVE', 'MEDIUM', 'DEBTOR-9013',
    '+212661009013', 'rachid.benjelloun@mail.ma', 'Rabat', '14 Avenue Hassan II', 1
WHERE NOT EXISTS (SELECT 1 FROM core.debtor WHERE debtor_reference = 'DEBTOR-9013');

INSERT INTO core.debt (uuid, code, description, is_delete, is_statut, create_date_time, update_date_time,
    debt_reference, amount_due, total_amount, overdue_amount, due_date, currency, creditor_id)
SELECT gen_random_uuid()::text, 'DEBT-9013', 'Demo creance incomplete', false, true, now(), now(),
    'DEBT-9013', 7000, 7000, 2000, CURRENT_DATE - 30, 'MAD', 1
WHERE NOT EXISTS (SELECT 1 FROM core.debt WHERE debt_reference = 'DEBT-9013');

INSERT INTO core.collection_case (uuid, code, description, is_delete, is_statut, create_date_time,
    update_date_time, case_reference, debt_id, debtor_id, creditor_id, portfolio_id, status, priority, phase,
    category_code, category_label, overdue_amount, total_debt_amount, days_late, has_active_promise,
    has_active_payment_plan, business_date)
SELECT gen_random_uuid()::text, 'CASE-9013', 'Demo dossier incomplet (montant total absent)', false, true, now(), now(),
    'CASE-9013',
    (SELECT id FROM core.debt WHERE debt_reference = 'DEBT-9013'),
    (SELECT id FROM core.debtor WHERE debtor_reference = 'DEBTOR-9013'),
    1, 1, 'OPEN', 'LOW', 'COLLECTION', 'PHONE_REMINDER', 'Rappel telephonique', 2000, NULL, 30, false, false,
    CURRENT_DATE
WHERE NOT EXISTS (SELECT 1 FROM core.collection_case WHERE case_reference = 'CASE-9013');
