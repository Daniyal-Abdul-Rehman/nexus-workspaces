-- Indexes for RLS membership checks and the documented hot paths.

CREATE INDEX org_memberships_user_org_role_idx
    ON public.organisation_memberships (user_id, organisation_id, role);

CREATE INDEX org_memberships_org_role_idx
    ON public.organisation_memberships (organisation_id, role);

CREATE INDEX org_memberships_owners_idx
    ON public.organisation_memberships (organisation_id, user_id)
    WHERE role = 'owner';

CREATE INDEX project_memberships_user_project_role_idx
    ON public.project_memberships (user_id, project_id, role);

CREATE INDEX project_memberships_project_role_idx
    ON public.project_memberships (project_id, role);

CREATE INDEX projects_org_activity_active_idx
    ON public.projects (organisation_id, last_activity_at DESC)
    WHERE status = 'active';

CREATE INDEX tasks_board_idx
    ON public.tasks (project_id, status, position)
    WHERE status IN ('todo', 'in_progress', 'done');

CREATE INDEX comments_project_created_idx
    ON public.comments (project_id, created_at DESC);

CREATE INDEX invitations_token_pending_idx
    ON public.invitations (token_digest)
    WHERE accepted_at IS NULL;

CREATE INDEX audit_events_org_created_idx
    ON public.audit_events (organisation_id, created_at DESC)
    WHERE organisation_id IS NOT NULL;
