-- Privileged operations that must be atomic. Callers cannot supply a user id;
-- identity is always auth.uid().

CREATE OR REPLACE FUNCTION public.write_audit(
    p_event_type text,
    p_organisation_id uuid,
    p_project_id uuid,
    p_resource_type text,
    p_resource_id uuid,
    p_old jsonb DEFAULT NULL,
    p_new jsonb DEFAULT NULL,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO public.audit_events (
        event_type, actor_id, organisation_id, project_id,
        resource_type, resource_id, old_values, new_values, metadata
    ) VALUES (
        p_event_type, auth.uid(), p_organisation_id, p_project_id,
        p_resource_type, p_resource_id, p_old, p_new, COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_organisation(p_name text, p_slug text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_org_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.organisations (name, slug, created_by)
    VALUES (p_name, p_slug, auth.uid())
    RETURNING id INTO v_org_id;

    INSERT INTO public.organisation_memberships (organisation_id, user_id, role)
    VALUES (v_org_id, auth.uid(), 'owner');

    PERFORM public.write_audit(
        'organisation.created', v_org_id, NULL, 'organisation', v_org_id,
        NULL, jsonb_build_object('name', p_name, 'slug', p_slug)
    );

    RETURN v_org_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.transfer_organisation_ownership(
    p_organisation_id uuid,
    p_new_owner_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_current_owner uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
    END IF;

    SELECT user_id INTO v_current_owner
    FROM public.organisation_memberships
    WHERE organisation_id = p_organisation_id
      AND role = 'owner'
    FOR UPDATE;

    IF v_current_owner IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Only the owner can transfer ownership' USING ERRCODE = '42501';
    END IF;

    IF p_new_owner_id = v_current_owner THEN
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.organisation_memberships
        WHERE organisation_id = p_organisation_id
          AND user_id = p_new_owner_id
          AND role IN ('admin', 'member')
    ) THEN
        RAISE EXCEPTION 'New owner must already be an admin or member';
    END IF;

    UPDATE public.organisation_memberships
    SET role = 'admin'
    WHERE organisation_id = p_organisation_id
      AND user_id = v_current_owner;

    UPDATE public.organisation_memberships
    SET role = 'owner'
    WHERE organisation_id = p_organisation_id
      AND user_id = p_new_owner_id;

    PERFORM public.write_audit(
        'organisation.ownership_transferred',
        p_organisation_id, NULL, 'organisation', p_organisation_id,
        jsonb_build_object('owner_id', v_current_owner),
        jsonb_build_object('owner_id', p_new_owner_id)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.invitation_token_digest(p_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions
AS $$
    SELECT encode(digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION public.accept_invitation(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_email text;
    v_invitation public.invitations%ROWTYPE;
    v_membership_id uuid;
    v_existing_role text;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
    END IF;

    IF p_token IS NULL OR length(p_token) < 16 THEN
        RAISE EXCEPTION 'Invalid invitation' USING ERRCODE = '22023';
    END IF;

    SELECT email INTO v_email
    FROM public.profiles
    WHERE id = v_user_id;

    SELECT * INTO v_invitation
    FROM public.invitations
    WHERE token_digest = public.invitation_token_digest(p_token)
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invalid invitation' USING ERRCODE = 'P0002';
    END IF;

    IF v_invitation.accepted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Invitation already accepted' USING ERRCODE = 'P0001';
    END IF;

    IF v_invitation.expires_at <= now() THEN
        RAISE EXCEPTION 'Invitation expired' USING ERRCODE = 'P0001';
    END IF;

    IF lower(v_invitation.email) IS DISTINCT FROM lower(v_email) THEN
        RAISE EXCEPTION 'Invitation is bound to a different email' USING ERRCODE = '42501';
    END IF;

    SELECT id, role INTO v_membership_id, v_existing_role
    FROM public.organisation_memberships
    WHERE organisation_id = v_invitation.organisation_id
      AND user_id = v_user_id
    FOR UPDATE;

    IF v_membership_id IS NULL THEN
        INSERT INTO public.organisation_memberships (organisation_id, user_id, role)
        VALUES (v_invitation.organisation_id, v_user_id, v_invitation.role)
        RETURNING id INTO v_membership_id;
    ELSIF v_existing_role = 'owner' THEN
        NULL;
    ELSE
        UPDATE public.organisation_memberships
        SET role = v_invitation.role
        WHERE id = v_membership_id
          AND role <> 'owner';
    END IF;

    UPDATE public.invitations
    SET accepted_at = now(),
        accepted_by = v_user_id
    WHERE id = v_invitation.id
      AND accepted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation already accepted' USING ERRCODE = 'P0001';
    END IF;

    PERFORM public.write_audit(
        'invitation.accepted',
        v_invitation.organisation_id, NULL, 'invitation', v_invitation.id,
        NULL,
        jsonb_build_object('role', v_invitation.role, 'membership_id', v_membership_id)
    );

    RETURN jsonb_build_object(
        'organisation_id', v_invitation.organisation_id,
        'role', v_invitation.role,
        'membership_id', v_membership_id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.transition_task_status(
    p_task_id uuid,
    p_new_status text,
    p_expected_version integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_task public.tasks%ROWTYPE;
    v_org_id uuid;
    v_updated public.tasks%ROWTYPE;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
    END IF;

    IF p_new_status NOT IN ('todo', 'in_progress', 'done', 'cancelled') THEN
        RAISE EXCEPTION 'Invalid status' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_task
    FROM public.tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task not found' USING ERRCODE = 'P0002';
    END IF;

    IF NOT public.can_update_task(p_task_id, v_user_id) THEN
        RAISE EXCEPTION 'Not authorised to update this task' USING ERRCODE = '42501';
    END IF;

    IF v_task.version IS DISTINCT FROM p_expected_version THEN
        RAISE EXCEPTION 'Task version mismatch'
            USING ERRCODE = 'P0001',
                DETAIL = format('expected %s current %s', p_expected_version, v_task.version);
    END IF;

    UPDATE public.tasks
    SET status = p_new_status,
        version = version + 1
    WHERE id = p_task_id
      AND version = p_expected_version
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Task version mismatch' USING ERRCODE = 'P0001';
    END IF;

    SELECT organisation_id INTO v_org_id
    FROM public.projects
    WHERE id = v_task.project_id;

    PERFORM public.write_audit(
        'task.status_changed',
        v_org_id, v_task.project_id, 'task', p_task_id,
        jsonb_build_object('status', v_task.status, 'version', v_task.version),
        jsonb_build_object('status', v_updated.status, 'version', v_updated.version)
    );

    RETURN jsonb_build_object(
        'task_id', v_updated.id,
        'status', v_updated.status,
        'version', v_updated.version
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.process_webhook_event(
    p_event_id text,
    p_source text,
    p_payload jsonb
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.webhook_events (event_id, source, payload, status)
    VALUES (p_event_id, p_source, p_payload, 'processed');

    INSERT INTO public.webhook_effects (event_id, effect_type)
    VALUES (p_event_id, COALESCE(p_payload->>'type', 'unknown'));

    RETURN 'processed';
EXCEPTION
    WHEN unique_violation THEN
        RETURN 'duplicate';
END;
$$;

REVOKE ALL ON FUNCTION public.write_audit(text, uuid, uuid, text, uuid, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_organisation(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.transfer_organisation_ownership(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.accept_invitation(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.transition_task_status(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_webhook_event(text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.invitation_token_digest(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_organisation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_organisation_ownership(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_invitation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transition_task_status(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.invitation_token_digest(text) TO authenticated;

GRANT EXECUTE ON FUNCTION public.process_webhook_event(text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.write_audit(text, uuid, uuid, text, uuid, jsonb, jsonb, jsonb) TO service_role;
