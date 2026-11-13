-- Retire les dossiers de demo (CASE-9001, 9003..9013, 0210) et leurs donnees liees. NE PAS lancer sur des dossiers reels.
-- psql "<url>" -f remove-demo-cases.sql   (ne touche que ces references)
BEGIN;
DELETE FROM core.payment_promise WHERE collection_case_id IN (SELECT id FROM core.collection_case WHERE case_reference IN ('CASE-0210','CASE-9001','CASE-9013') OR case_reference BETWEEN 'CASE-9003' AND 'CASE-9012');
DELETE FROM core.collection_case WHERE case_reference IN ('CASE-0210','CASE-9001','CASE-9013') OR case_reference BETWEEN 'CASE-9003' AND 'CASE-9012';
DELETE FROM core.debt WHERE debt_reference IN ('DEBT-210','DEBT-9001','DEBT-9013') OR debt_reference BETWEEN 'DEBT-9003' AND 'DEBT-9012';
DELETE FROM core.debtor WHERE debtor_reference IN ('DEBTOR-210','DEBTOR-9001','DEBTOR-9013') OR debtor_reference BETWEEN 'DEBTOR-9003' AND 'DEBTOR-9012';
COMMIT;
