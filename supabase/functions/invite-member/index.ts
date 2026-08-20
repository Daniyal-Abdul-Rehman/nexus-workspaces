import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

interface InviteRequest {
  organisation_id: string
  email: string
  role: 'admin' | 'member' | 'guest'
}

interface InviteResponse {
  success: boolean
  invitation_id?: string
  invite_url?: string
  error?: string
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const { organisation_id, email, role }: InviteRequest = await req.json()

    if (!organisation_id || !email || !role) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields: organisation_id, email, role' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!['admin', 'member', 'guest'].includes(role)) {
      return new Response(
        JSON.stringify({ error: 'Invalid role. Must be admin, member, or guest' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    if (!emailRegex.test(email)) {
      return new Response(
        JSON.stringify({ error: 'Invalid email format' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing Supabase environment variables')
    }

    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      }
    })

    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace('Bearer ', '')
    )

    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Invalid authentication token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const { data: membership, error: membershipError } = await supabase
      .from('organisation_memberships')
      .select('role')
      .eq('organisation_id', organisation_id)
      .eq('user_id', user.id)
      .single()

    if (membershipError || !membership) {
      return new Response(
        JSON.stringify({ error: 'You are not a member of this organisation' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (membership.role !== 'owner' && membership.role !== 'admin') {
      return new Response(
        JSON.stringify({ error: 'Only owners and admins can create invitations' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const token = crypto.randomUUID()
    const tokenBytes = new TextEncoder().encode(token)
    const hashBuffer = await crypto.subtle.digest('SHA-256', tokenBytes)
    const tokenDigest = Array.from(new Uint8Array(hashBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('')

    const expiresAt = new Date()
    expiresAt.setDate(expiresAt.getDate() + 7)

    const { data: existingInvitation } = await supabase
      .from('invitations')
      .select('id')
      .eq('organisation_id', organisation_id)
      .eq('email', email.toLowerCase())
      .is('accepted_at', null)
      .gt('expires_at', new Date().toISOString())
      .single()

    if (existingInvitation) {
      const devInviteUrl = `${supabaseUrl}/auth/v1/verify?token=${token}&type=invite`
      
      return new Response(
        JSON.stringify({
          success: true,
          invitation_id: existingInvitation.id,
          invite_url: devInviteUrl,
          message: 'Existing pending invitation found'
        } as InviteResponse),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const { data: invitation, error: inviteError } = await supabase
      .from('invitations')
      .insert({
        organisation_id,
        email: email.toLowerCase(),
        role,
        token_digest: tokenDigest,
        expires_at: expiresAt.toISOString(),
        created_by: user.id
      })
      .select('id')
      .single()

    if (inviteError) {
      console.error('Error creating invitation:', inviteError)
      return new Response(
        JSON.stringify({ error: 'Failed to create invitation' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const devInviteUrl = `${supabaseUrl}/auth/v1/verify?token=${token}&type=invite`

    await supabase.rpc('create_audit_event', {
      p_event_type: 'invitation.created',
      p_actor_id: user.id,
      p_resource_type: 'invitation',
      p_organisation_id: organisation_id,
      p_resource_id: invitation.id,
      p_new_values: { email, role, expires_at: expiresAt.toISOString() },
      p_metadata: { method: 'edge_function' }
    })

    const response: InviteResponse = {
      success: true,
      invitation_id: invitation.id,
      invite_url: devInviteUrl
    }

    return new Response(
      JSON.stringify(response),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Error in invite-member function:', error)
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})