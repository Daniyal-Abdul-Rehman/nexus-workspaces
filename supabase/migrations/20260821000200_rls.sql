-- Access helpers are SECURITY DEFINER so membership policies never recurse.
-- Parameter names are prefixed to avoid colliding with column names.
-- search_path is empty; all objects are schema-qualified.

CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.org_role(p_organisation_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT om.role
    FROM public.organisation_memberships AS om
    WHERE om.organisation_id = p_organisation_id
      AND om.user_id = p_user_id;
$$;

CREATE OR REPLACE FUNCTION public.project_role(p_project_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT pm.role
    FROM public.project_memberships AS pm
    WHERE pm.project_id = p_project_id
      AND pm.user_id = p_user_id;
$$;

CREATE OR REPLACE FUNCTION public.is_org_staff(p_organisation_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.org_role(p_organisation_id, p_user_id) IN ('owner', 'admin');
$$;

CREATE OR REPLACE FUNCTION public.is_org_owner(p_organisation_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.org_role(p_organisation_id, p_user_id) = 'owner';
$$;

-- Pre-confidential rule: organisation owners and admins automatically see
-- every project in the organisation. Explicit project membership also grants access.
CREATE OR REPLACE FUNCTION public.has_project_access(p_project_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_org_id uuid;
    v_org_role text;
BEGIN
    IF p_user_id IS NULL OR p_project_id IS NULL THEN
        RETURN false;
    END IF;

    SELECT p.organisation_id INTO v_org_id
    FROM public.projects AS p
    WHERE p.id = p_project_id;

    IF v_org_id IS NULL THEN
        RETURN false;
    END IF;

    v_org_role := public.org_role(v_org_id, p_user_id);

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
BEGIN
    SELECT p.organisation_id INTO v_org_id
    FROM public.projects AS p
    WHERE p.id = p_project_id;

    IF v_org_id IS NULL THEN
        RETURN false;
    END IF;

    IF public.is_org_staff(v_org_id, p_user_id) THEN
        RETURN true;
    END IF;

    RETURN public.project_role(p_project_id, p_user_id) = 'manager';
END;
$$;

CREATE OR REPLACE FUNCTION public.can_archive_project(p_project_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.is_org_staff(
        (SELECT p.organisation_id FROM public.projects AS p WHERE p.id = p_project_id),
        p_user_id
    )
    AND public.has_project_access(p_project_id, p_user_id);
$$;

CREATE OR REPLACE FUNCTION public.can_mutate_project_content(p_project_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_org_id uuid;
    v_org_role text;
    v_project_role text;
BEGIN
    IF NOT public.has_project_access(p_project_id, p_user_id) THEN
        RETURN false;
    END IF;

    SELECT p.organisation_id INTO v_org_id
    FROM public.projects AS p
    WHERE p.id = p_project_id;

    v_org_role := public.org_role(v_org_id, p_user_id);
    v_project_role := public.project_role(p_project_id, p_user_id);

    RETURN v_org_role IN ('owner', 'admin')
        OR v_project_role IN ('manager', 'contributor');
END;
$$;

CREATE OR REPLACE FUNCTION public.can_update_task(p_task_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_task public.tasks%ROWTYPE;
BEGIN
    SELECT * INTO v_task
    FROM public.tasks AS t
    WHERE t.id = p_task_id;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    IF public.can_manage_project(v_task.project_id, p_user_id) THEN
        RETURN true;
    END IF;

    IF NOT public.can_mutate_project_content(v_task.project_id, p_user_id) THEN
        RETURN false;
    END IF;

    RETURN v_task.created_by = p_user_id OR v_task.assigned_to = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.can_moderate_comment(p_comment_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_comment public.comments%ROWTYPE;
BEGIN
    SELECT * INTO v_comment
    FROM public.comments AS c
    WHERE c.id = p_comment_id;

    IF NOT FOUND THEN
        RETURN false;
    END IF;

    IF v_comment.author_id = p_user_id AND public.has_project_access(v_comment.project_id, p_user_id) THEN
        RETURN true;
    END IF;

    RETURN public.can_manage_project(v_comment.project_id, p_user_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.shares_visible_profile(p_profile_id uuid, p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT p_profile_id = p_user_id
        OR EXISTS (
            SELECT 1
            FROM public.organisation_memberships AS mine
            JOIN public.organisation_memberships AS theirs
              ON theirs.organisation_id = mine.organisation_id
            WHERE mine.user_id = p_user_id
              AND theirs.user_id = p_profile_id
              AND mine.role IN ('owner', 'admin', 'member')
        )
        OR EXISTS (
            SELECT 1
            FROM public.project_memberships AS mine
            JOIN public.project_memberships AS theirs
              ON theirs.project_id = mine.project_id
            WHERE mine.user_id = p_user_id
              AND theirs.user_id = p_profile_id
        );
$$;

CREATE OR REPLACE FUNCTION public.try_uuid(p_value text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN p_value::uuid;
EXCEPTION
    WHEN invalid_text_representation THEN
        RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.storage_org_id(p_object_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT public.try_uuid(split_part(p_object_name, '/', 1));
$$;

CREATE OR REPLACE FUNCTION public.storage_project_id(p_object_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT public.try_uuid(split_part(p_object_name, '/', 2));
$$;

CREATE OR REPLACE FUNCTION public.storage_uploader_id(p_object_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT public.try_uuid(split_part(p_object_name, '/', 3));
$$;

CREATE OR REPLACE FUNCTION public.storage_path_matches_project(p_object_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.projects AS p
        WHERE p.id = public.storage_project_id(p_object_name)
          AND p.organisation_id = public.storage_org_id(p_object_name)
    );
$$;

REVOKE ALL ON FUNCTION public.org_role(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.project_role(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_org_staff(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_org_owner(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.has_project_access(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_manage_project(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_archive_project(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_mutate_project_content(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_update_task(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.can_moderate_comment(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.shares_visible_profile(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.storage_path_matches_project(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.org_role(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.project_role(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_org_staff(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_org_owner(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_project_access(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_project(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_archive_project(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_mutate_project_content(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_update_task(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_moderate_comment(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.shares_visible_profile(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.storage_path_matches_project(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.try_uuid(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.storage_org_id(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.storage_project_id(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.storage_uploader_id(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_user_id() TO authenticated;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organisations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organisation_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.project_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.webhook_effects ENABLE ROW LEVEL SECURITY;

CREATE POLICY profiles_select ON public.profiles
    FOR SELECT TO authenticated
    USING (public.shares_visible_profile(id));

CREATE POLICY profiles_update ON public.profiles
    FOR UPDATE TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid() AND email IS NOT DISTINCT FROM email);

CREATE POLICY organisations_select ON public.organisations
    FOR SELECT TO authenticated
    USING (public.org_role(id) IS NOT NULL);

CREATE POLICY organisations_update ON public.organisations
    FOR UPDATE TO authenticated
    USING (public.is_org_staff(id))
    WITH CHECK (public.is_org_staff(id));

CREATE POLICY organisations_delete ON public.organisations
    FOR DELETE TO authenticated
    USING (public.is_org_owner(id));

CREATE POLICY organisation_memberships_select_own ON public.organisation_memberships
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

CREATE POLICY organisation_memberships_select_staff_member ON public.organisation_memberships
    FOR SELECT TO authenticated
    USING (public.org_role(organisation_id) IN ('owner', 'admin', 'member'));

CREATE POLICY organisation_memberships_update ON public.organisation_memberships
    FOR UPDATE TO authenticated
    USING (
        public.is_org_staff(organisation_id)
        AND role <> 'owner'
    )
    WITH CHECK (
        (
            public.is_org_owner(organisation_id)
            AND role IN ('admin', 'member', 'guest')
        )
        OR (
            public.org_role(organisation_id) = 'admin'
            AND role IN ('member', 'guest')
        )
    );

CREATE POLICY organisation_memberships_delete ON public.organisation_memberships
    FOR DELETE TO authenticated
    USING (
        (user_id = auth.uid() AND role <> 'owner')
        OR (
            public.is_org_owner(organisation_id)
            AND role <> 'owner'
        )
        OR (
            public.org_role(organisation_id) = 'admin'
            AND role IN ('member', 'guest')
        )
    );

CREATE POLICY projects_select ON public.projects
    FOR SELECT TO authenticated
    USING (public.has_project_access(id));

CREATE POLICY projects_insert ON public.projects
    FOR INSERT TO authenticated
    WITH CHECK (public.is_org_staff(organisation_id) AND created_by = auth.uid());

CREATE POLICY projects_update ON public.projects
    FOR UPDATE TO authenticated
    USING (public.can_manage_project(id))
    WITH CHECK (public.can_manage_project(id));

CREATE POLICY projects_delete ON public.projects
    FOR DELETE TO authenticated
    USING (public.can_archive_project(id));

CREATE POLICY project_memberships_select ON public.project_memberships
    FOR SELECT TO authenticated
    USING (public.has_project_access(project_id));

CREATE POLICY project_memberships_insert ON public.project_memberships
    FOR INSERT TO authenticated
    WITH CHECK (public.can_manage_project(project_id));

CREATE POLICY project_memberships_update ON public.project_memberships
    FOR UPDATE TO authenticated
    USING (public.can_manage_project(project_id))
    WITH CHECK (public.can_manage_project(project_id));

CREATE POLICY project_memberships_delete ON public.project_memberships
    FOR DELETE TO authenticated
    USING (public.can_manage_project(project_id));

CREATE POLICY tasks_select ON public.tasks
    FOR SELECT TO authenticated
    USING (public.has_project_access(project_id));

CREATE POLICY tasks_insert ON public.tasks
    FOR INSERT TO authenticated
    WITH CHECK (
        public.can_mutate_project_content(project_id)
        AND created_by = auth.uid()
    );

CREATE POLICY tasks_update ON public.tasks
    FOR UPDATE TO authenticated
    USING (public.can_update_task(id))
    WITH CHECK (public.can_update_task(id));

CREATE POLICY tasks_delete ON public.tasks
    FOR DELETE TO authenticated
    USING (public.can_manage_project(project_id));

CREATE POLICY comments_select ON public.comments
    FOR SELECT TO authenticated
    USING (public.has_project_access(project_id));

CREATE POLICY comments_insert ON public.comments
    FOR INSERT TO authenticated
    WITH CHECK (
        public.can_mutate_project_content(project_id)
        AND author_id = auth.uid()
    );

CREATE POLICY comments_update ON public.comments
    FOR UPDATE TO authenticated
    USING (public.can_moderate_comment(id))
    WITH CHECK (public.can_moderate_comment(id) AND author_id IS NOT DISTINCT FROM author_id);

CREATE POLICY comments_delete ON public.comments
    FOR DELETE TO authenticated
    USING (public.can_moderate_comment(id));

CREATE POLICY invitations_select ON public.invitations
    FOR SELECT TO authenticated
    USING (
        public.is_org_staff(organisation_id)
        OR lower(email) = lower((SELECT p.email FROM public.profiles AS p WHERE p.id = auth.uid()))
    );

CREATE POLICY invitations_insert ON public.invitations
    FOR INSERT TO authenticated
    WITH CHECK (
        public.is_org_staff(organisation_id)
        AND created_by = auth.uid()
        AND role IN ('admin', 'member', 'guest')
        AND (
            public.is_org_owner(organisation_id)
            OR role IN ('member', 'guest')
        )
    );

CREATE POLICY invitations_update ON public.invitations
    FOR UPDATE TO authenticated
    USING (public.is_org_staff(organisation_id) AND accepted_at IS NULL)
    WITH CHECK (public.is_org_staff(organisation_id));

CREATE POLICY invitations_delete ON public.invitations
    FOR DELETE TO authenticated
    USING (public.is_org_staff(organisation_id) AND accepted_at IS NULL);

CREATE POLICY audit_events_select ON public.audit_events
    FOR SELECT TO authenticated
    USING (
        organisation_id IS NOT NULL
        AND public.is_org_staff(organisation_id)
    );
