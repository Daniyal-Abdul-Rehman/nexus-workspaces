-- Maintainability change: confidential projects drop automatic admin access.
-- Access decisions stay inside has_project_access / can_manage_project /
-- can_archive_project so Storage and Realtime policies do not change.

ALTER TABLE public.projects
    ADD COLUMN access_mode TEXT NOT NULL DEFAULT 'normal'
        CHECK (access_mode IN ('normal', 'confidential'));

CREATE INDEX projects_confidential_idx
    ON public.projects (organisation_id)
    WHERE access_mode = 'confidential';

CREATE OR REPLACE FUNCTION public.has_project_access(p_project_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_org_id uuid;
    v_access_mode text;
    v_org_role text;
BEGIN
    IF p_user_id IS NULL OR p_project_id IS NULL THEN
        RETURN false;
    END IF;

    SELECT p.organisation_id, p.access_mode
    INTO v_org_id, v_access_mode
    FROM public.projects AS p
    WHERE p.id = p_project_id;

    IF v_org_id IS NULL THEN
        RETURN false;
    END IF;

    v_org_role := public.org_role(v_org_id, p_user_id);

    IF v_access_mode = 'confidential' THEN
        RETURN v_org_role = 'owner'
            OR public.project_role(p_project_id, p_user_id) IS NOT NULL;
    END IF;

    IF v_org_role IN ('owner', 'admin') THEN
        RETURN true;
    END IF;

    RETURN public.project_role(p_project_id, p_user_id) IS NOT NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.can_manage_project(p_project_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_org_id uuid;
    v_access_mode text;
    v_org_role text;
BEGIN
    SELECT p.organisation_id, p.access_mode
    INTO v_org_id, v_access_mode
    FROM public.projects AS p
    WHERE p.id = p_project_id;

    IF v_org_id IS NULL THEN
        RETURN false;
    END IF;

    v_org_role := public.org_role(v_org_id, p_user_id);

    IF v_access_mode = 'confidential' THEN
        RETURN v_org_role = 'owner'
            OR public.project_role(p_project_id, p_user_id) = 'manager';
    END IF;

    IF v_org_role IN ('owner', 'admin') THEN
        RETURN true;
    END IF;

    RETURN public.project_role(p_project_id, p_user_id) = 'manager';
END;
$$;

CREATE OR REPLACE FUNCTION public.can_archive_project(p_project_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_org_id uuid;
    v_access_mode text;
    v_org_role text;
BEGIN
    SELECT p.organisation_id, p.access_mode
    INTO v_org_id, v_access_mode
    FROM public.projects AS p
    WHERE p.id = p_project_id;

    IF v_org_id IS NULL THEN
        RETURN false;
    END IF;

    v_org_role := public.org_role(v_org_id, p_user_id);

    IF v_access_mode = 'confidential' THEN
        RETURN v_org_role = 'owner';
    END IF;

    RETURN v_org_role IN ('owner', 'admin');
END;
$$;

CREATE OR REPLACE FUNCTION public.audit_access_mode_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF OLD.access_mode IS DISTINCT FROM NEW.access_mode THEN
        INSERT INTO public.audit_events (
            event_type, actor_id, organisation_id, project_id,
            resource_type, resource_id, old_values, new_values
        ) VALUES (
            'project.access_mode_changed',
            auth.uid(),
            NEW.organisation_id,
            NEW.id,
            'project',
            NEW.id,
            jsonb_build_object('access_mode', OLD.access_mode),
            jsonb_build_object('access_mode', NEW.access_mode)
        );
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_access_mode_change
    AFTER UPDATE OF access_mode ON public.projects
    FOR EACH ROW EXECUTE FUNCTION public.audit_access_mode_change();
