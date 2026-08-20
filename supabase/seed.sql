-- Seed SQL file for Supabase local development
-- This file is automatically run after migrations during `supabase db reset`
-- It references the main seed data migration

-- The actual seed data is in the migration file:
-- supabase/migrations/20260820201623_seed_data.sql

-- This file is kept minimal as the seed data is included in the migration
-- which ensures it's always applied after schema changes

-- For reference, the seed data includes:
-- - 6 test users with different roles
-- - 2 organisations for cross-tenant testing
-- - 4 projects including confidential projects
-- - 6 project memberships testing different access scenarios
-- - 6 tasks for basic functionality testing
-- - 5 comments for testing comment access
-- - 2 invitations (1 pending, 1 accepted) for testing invitation workflow
-- - 4 audit events for testing audit trail
-- - 100 scale projects for performance testing
-- - 10,000 scale tasks for performance testing
-- - 50,000 scale comments for performance testing

-- To create the corresponding auth.users records, run:
-- deno run --allow-net --allow-env scripts/create-test-users.ts