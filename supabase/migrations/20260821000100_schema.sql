-- Nexus Workspaces core schema.
-- Roles use TEXT + CHECK rather than ENUM so later product roles can ship
-- as a data migration instead of a lock-breaking ALTER TYPE.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    full_name TEXT,
    avatar_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX profiles_email_lower_idx ON public.profiles (lower(email));

CREATE TABLE public.organisations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
    slug TEXT NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$'),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'archived')),
    created_by UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (slug)
);

CREATE TABLE public.organisation_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organisation_id UUID NOT NULL REFERENCES public.organisations (id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'guest')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (organisation_id, user_id)
);

CREATE UNIQUE INDEX organisation_one_owner_idx
    ON public.organisation_memberships (organisation_id)
    WHERE role = 'owner';

CREATE TABLE public.projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organisation_id UUID NOT NULL REFERENCES public.organisations (id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
    description TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.project_memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('manager', 'contributor', 'viewer')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (project_id, user_id)
);

CREATE TABLE public.tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
    title TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 240),
    description TEXT,
    status TEXT NOT NULL DEFAULT 'todo' CHECK (status IN ('todo', 'in_progress', 'done', 'cancelled')),
    position INTEGER NOT NULL DEFAULT 0,
    version INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_by UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    assigned_to UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
    task_id UUID REFERENCES public.tasks (id) ON DELETE CASCADE,
    author_id UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    content TEXT NOT NULL CHECK (char_length(content) BETWEEN 1 AND 20000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organisation_id UUID NOT NULL REFERENCES public.organisations (id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('admin', 'member', 'guest')),
    token_digest TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    accepted_at TIMESTAMPTZ,
    accepted_by UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    created_by UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (expires_at > created_at),
    UNIQUE (token_digest)
);

CREATE UNIQUE INDEX invitations_pending_email_org_idx
    ON public.invitations (organisation_id, lower(email))
    WHERE accepted_at IS NULL;

CREATE TABLE public.audit_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    actor_id UUID REFERENCES public.profiles (id) ON DELETE SET NULL,
    organisation_id UUID REFERENCES public.organisations (id) ON DELETE SET NULL,
    project_id UUID REFERENCES public.projects (id) ON DELETE SET NULL,
    resource_type TEXT NOT NULL,
    resource_id UUID,
    old_values JSONB,
    new_values JSONB,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.webhook_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id TEXT NOT NULL,
    source TEXT NOT NULL,
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'processed' CHECK (status IN ('processed', 'duplicate', 'rejected')),
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (event_id)
);

CREATE TABLE public.webhook_effects (
    event_id TEXT PRIMARY KEY REFERENCES public.webhook_events (event_id) ON DELETE CASCADE,
    effect_type TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_organisations_updated_at
    BEFORE UPDATE ON public.organisations
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_organisation_memberships_updated_at
    BEFORE UPDATE ON public.organisation_memberships
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_projects_updated_at
    BEFORE UPDATE ON public.projects
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_project_memberships_updated_at
    BEFORE UPDATE ON public.project_memberships
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_comments_updated_at
    BEFORE UPDATE ON public.comments
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.touch_project_activity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.projects
    SET last_activity_at = now()
    WHERE id = NEW.project_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tasks_activity
    AFTER INSERT OR UPDATE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION public.touch_project_activity();
CREATE TRIGGER trg_comments_activity
    AFTER INSERT ON public.comments
    FOR EACH ROW EXECUTE FUNCTION public.touch_project_activity();

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1))
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE OR REPLACE FUNCTION public.enforce_project_membership_invariants()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_org UUID;
    v_org_role TEXT;
BEGIN
    SELECT organisation_id INTO v_org
    FROM public.projects
    WHERE id = NEW.project_id;

    SELECT role INTO v_org_role
    FROM public.organisation_memberships
    WHERE organisation_id = v_org
      AND user_id = NEW.user_id;

    IF v_org_role IS NULL THEN
        RAISE EXCEPTION 'Project members must belong to the organisation';
    END IF;

    IF NEW.role = 'manager' AND v_org_role = 'guest' THEN
        RAISE EXCEPTION 'Guests cannot be project managers';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_project_membership_invariants
    BEFORE INSERT OR UPDATE ON public.project_memberships
    FOR EACH ROW EXECUTE FUNCTION public.enforce_project_membership_invariants();

CREATE OR REPLACE FUNCTION public.enforce_comment_task_scope()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_task_project UUID;
BEGIN
    IF NEW.task_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT project_id INTO v_task_project
    FROM public.tasks
    WHERE id = NEW.task_id;

    IF v_task_project IS DISTINCT FROM NEW.project_id THEN
        RAISE EXCEPTION 'Comment task must belong to the same project';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_comment_task_scope
    BEFORE INSERT OR UPDATE ON public.comments
    FOR EACH ROW EXECUTE FUNCTION public.enforce_comment_task_scope();

CREATE OR REPLACE FUNCTION public.prevent_task_project_move()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.project_id IS DISTINCT FROM OLD.project_id THEN
        RAISE EXCEPTION 'Tasks cannot be moved between projects';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prevent_task_project_move
    BEFORE UPDATE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION public.prevent_task_project_move();

CREATE OR REPLACE FUNCTION public.prevent_project_org_move()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.organisation_id IS DISTINCT FROM OLD.organisation_id THEN
        RAISE EXCEPTION 'Projects cannot be moved between organisations';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prevent_project_org_move
    BEFORE UPDATE ON public.projects
    FOR EACH ROW EXECUTE FUNCTION public.prevent_project_org_move();

CREATE OR REPLACE FUNCTION public.protect_audit_events()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit_events is append-only';
END;
$$;

CREATE TRIGGER trg_audit_events_immutable
    BEFORE UPDATE OR DELETE ON public.audit_events
    FOR EACH ROW EXECUTE FUNCTION public.protect_audit_events();

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA public TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.audit_events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.webhook_events FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.webhook_effects FROM authenticated;
GRANT SELECT ON public.audit_events TO authenticated;
REVOKE ALL ON public.webhook_events FROM authenticated, anon;
REVOKE ALL ON public.webhook_effects FROM authenticated, anon;
