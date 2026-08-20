import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4'
import { crypto } from 'https://deno.land/std@0.168.0/crypto/mod.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-webhook-signature, x-webhook-timestamp, x-webhook-id',
}

interface WebhookResponse {
  success: boolean
  message?: string
  event_id?: string
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    if (req.method !== 'POST') {
      return new Response(
        JSON.stringify({ error: 'Method not allowed' }),
        { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const signature = req.headers.get('x-webhook-signature')
    const timestamp = req.headers.get('x-webhook-timestamp')
    const eventId = req.headers.get('x-webhook-id')
    const source = req.headers.get('x-webhook-source') || 'unknown'

    if (!signature || !timestamp || !eventId) {
      return new Response(
        JSON.stringify({ error: 'Missing required webhook headers' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const webhookSecret = Deno.env.get('WEBHOOK_SECRET')
    if (!webhookSecret) {
      console.error('WEBHOOK_SECRET not configured')
      return new Response(
        JSON.stringify({ error: 'Webhook configuration error' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const rawBody = await req.text()

    const webhookTimestamp = parseInt(timestamp, 10)
    const currentTime = Math.floor(Date.now() / 1000)
    const timeWindow = 300

    if (Math.abs(currentTime - webhookTimestamp) > timeWindow) {
      return new Response(
        JSON.stringify({ error: 'Webhook timestamp too old or in future' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const expectedSignaturePrefix = 'sha256='
    if (!signature.startsWith(expectedSignaturePrefix)) {
      return new Response(
        JSON.stringify({ error: 'Invalid signature format' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const receivedSignature = signature.substring(expectedSignaturePrefix.length)

    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(webhookSecret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    )

    const timestampedBody = `${timestamp}.${rawBody}`
    const signatureBytes = await crypto.subtle.sign(
      'HMAC',
      key,
      new TextEncoder().encode(timestampedBody)
    )

    const expectedSignature = Array.from(new Uint8Array(signatureBytes))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('')

    const signatureMatch = await timingSafeEqual(
      receivedSignature,
      expectedSignature
    )

    if (!signatureMatch) {
      console.warn('Webhook signature verification failed')
      return new Response(
        JSON.stringify({ error: 'Invalid signature' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
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

    const { data: existingEvent } = await supabase
      .from('webhook_events')
      .select('id, status')
      .eq('event_id', eventId)
      .single()

    if (existingEvent) {
      if (existingEvent.status === 'processed') {
        return new Response(
          JSON.stringify({
            success: true,
            message: 'Event already processed',
            event_id: eventId
          } as WebhookResponse),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      } else if (existingEvent.status === 'failed') {
        await supabase
          .from('webhook_events')
          .update({ status: 'pending', error_message: null })
          .eq('id', existingEvent.id)
      } else {
        return new Response(
          JSON.stringify({
            success: false,
            message: 'Event currently being processed',
            event_id: eventId
          } as WebhookResponse),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
    } else {
      const { error: insertError } = await supabase
        .from('webhook_events')
        .insert({
          event_id: eventId,
          source,
          signature,
          payload: JSON.parse(rawBody),
          status: 'pending'
        })

      if (insertError) {
        console.error('Error creating webhook event record:', insertError)
        return new Response(
          JSON.stringify({ error: 'Failed to record webhook event' }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        )
      }
    }

    let processingSuccess = true
    let errorMessage = null

    try {
      const payload = JSON.parse(rawBody)
      
      switch (payload.type) {
        case 'user.created':
          console.log('Processing user.created event:', payload)
          break
        case 'user.updated':
          console.log('Processing user.updated event:', payload)
          break
        case 'payment.completed':
          console.log('Processing payment.completed event:', payload)
          break
        default:
          console.log('Processing unknown event type:', payload.type)
      }

    } catch (processingError) {
      console.error('Error processing webhook payload:', processingError)
      processingSuccess = false
      errorMessage = processingError.message
    }

    const { error: updateError } = await supabase
      .from('webhook_events')
      .update({
        status: processingSuccess ? 'processed' : 'failed',
        processed_at: new Date().toISOString(),
        error_message: errorMessage
      })
      .eq('event_id', eventId)

    if (updateError) {
      console.error('Error updating webhook event status:', updateError)
    }

    if (processingSuccess) {
      return new Response(
        JSON.stringify({
          success: true,
          message: 'Webhook processed successfully',
          event_id: eventId
        } as WebhookResponse),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    } else {
      return new Response(
        JSON.stringify({
          success: false,
          message: 'Webhook processing failed',
          event_id: eventId
        } as WebhookResponse),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

  } catch (error) {
    console.error('Error in external-webhook function:', error)
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})

async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  if (a.length !== b.length) {
    return false
  }

  const aBytes = new TextEncoder().encode(a)
  const bBytes = new TextEncoder().encode(b)

  const result = await crypto.subtle.timingSafeEqual(aBytes, bBytes)
  return result
}