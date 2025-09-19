import express from 'express';
import fetch from 'node-fetch';

const app = express();
app.use(express.json({ limit: '1mb' }));

// ENV & constants
const UPSTREAM_BASE_MODEL = process.env.UPSTREAM_BASE_MODEL || 'meta-llama/llama-3.2-3b-instruct';
const PUBLIC_MODEL        = process.env.PUBLIC_MODEL || 'meta-llama/llama-3.2-3b-instruct/fp-16-fast-vllm-1';
const ALIASES_ENV         = (process.env.MODEL_ALIASES || '').split(',').map(s=>s.trim()).filter(Boolean);
const NOVITA_KEY          = process.env.NOVITA_API_KEY || '';
const PORT                = Number(process.env.PROXY_PORT || 14000);
const STREAM_CHUNK_SIZE   = Number(process.env.STREAM_CHUNK_SIZE || 64);
const STREAM_DELAY_MS     = Number(process.env.STREAM_DELAY_MS || 30);

// Kandidat endpoint OpenAI-compatible (bisa override via env, pisah ';')
const NOVITA_OPENAI_ENDPOINTS = (process.env.NOVITA_OPENAI_ENDPOINTS || [
  'https://api.novita.ai/v3/openai/chat/completions',
  'https://api.novita.ai/openai/v1/chat/completions',
  'https://api.novita.ai/v1/chat/completions'
].join(';')).split(';').map(s => s.trim()).filter(Boolean);

const SUFFIX_STRIP_REGEX = /(\/fp-16-fast-vllm-\d+)$|(:fp16)$|(:fp-16)$/i;

function log(...a){ console.log('[novita-proxy]', ...a); }
function compactForm(s){ return (s || '').toLowerCase().replace(/[\/:_\-\.]/g,''); }
function stripSuffix(m){ return (m || '').replace(SUFFIX_STRIP_REGEX, ''); }

function buildAliasSet() {
  const set = new Set(ALIASES_ENV);
  set.add(UPSTREAM_BASE_MODEL);
  set.add(PUBLIC_MODEL);
  set.add(compactForm(UPSTREAM_BASE_MODEL));
  set.add(compactForm(PUBLIC_MODEL));
  return Array.from(set);
}
const ALIASES = buildAliasSet();

function normalizeIncoming(name) {
  if (!name) return PUBLIC_MODEL;
  if (name === PUBLIC_MODEL) return PUBLIC_MODEL;
  if (name === UPSTREAM_BASE_MODEL) return PUBLIC_MODEL;
  if (ALIASES.includes(name)) return PUBLIC_MODEL;
  const cmp = compactForm(name);
  if (cmp === compactForm(UPSTREAM_BASE_MODEL) || cmp === compactForm(PUBLIC_MODEL)) return PUBLIC_MODEL;
  if (stripSuffix(name) === UPSTREAM_BASE_MODEL) return PUBLIC_MODEL;
  return PUBLIC_MODEL;
}
function mapToUpstream(publicOrAlias) {
  if (!publicOrAlias) return UPSTREAM_BASE_MODEL;
  if (publicOrAlias === PUBLIC_MODEL) return UPSTREAM_BASE_MODEL;
  const stripped = stripSuffix(publicOrAlias);
  if (compactForm(stripped) === compactForm(UPSTREAM_BASE_MODEL)) return UPSTREAM_BASE_MODEL;
  return UPSTREAM_BASE_MODEL;
}
function buildMessages({ prompt, messages }) {
  if (messages && Array.isArray(messages) && messages.length) return messages;
  if (prompt) return [{ role:'user', content: prompt }];
  return null;
}

app.get('/healthz', (_req,res)=>{
  res.json({
    ok:true,
    public_model: PUBLIC_MODEL,
    upstream_base: UPSTREAM_BASE_MODEL,
    aliases: ALIASES,
    novita_endpoints: NOVITA_OPENAI_ENDPOINTS
  });
});

app.get('/api/tags', (_req,res)=>{
  res.json({ models: [{ name: PUBLIC_MODEL, upstream: UPSTREAM_BASE_MODEL, aliases: ALIASES }] });
});

// Emulasi sukses /api/pull ala Ollama (tanpa download)
app.post('/api/pull', (req,res)=>{
  res.setHeader('Content-Type','application/x-ndjson');
  const model = req.body?.model || req.body?.name || PUBLIC_MODEL;
  for (const l of [
    { status: `pulling ${model}` },
    { status: 'verifying sha256' },
    { status: 'writing manifest' },
    { status: 'success' }
  ]) res.write(JSON.stringify(l) + '\n');
  res.end();
});

// Non-stream call helper (selalu stream:false ke upstream)
async function callNovitaChatCompletion(upstreamPayload) {
  const attempts = [];
  for (const url of NOVITA_OPENAI_ENDPOINTS) {
    try {
      const resp = await fetch(url, {
        method:'POST',
        headers:{
          'Authorization': `Bearer ${NOVITA_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ ...upstreamPayload, stream: false })
      });
      const text = await resp.text();
      if (resp.ok) {
        try {
          const data = JSON.parse(text);
          return { ok:true, data, url };
        } catch (e) {
          return { ok:false, status: resp.status, url, detail: `invalid_json: ${String(e)}`, body: text.slice(0,800) };
        }
      }
      attempts.push({ url, status: resp.status, body: text.slice(0, 800) });
    } catch (e) {
      attempts.push({ url, error: String(e) });
    }
  }
  return { ok:false, attempts };
}

// Util kirim SSE simulasi ala OpenAI dari full text
async function sendSimulatedSSE({ res, model, text }) {
  const streamId = 'chatcmpl_' + Math.random().toString(36).slice(2);
  const out = (obj) => res.write(`data: ${JSON.stringify(obj)}\n\n`);

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');

  // Chunk 1: role
  out({
    id: streamId,
    object: 'chat.completion.chunk',
    created: Math.floor(Date.now()/1000),
    model,
    choices: [{ index: 0, delta: { role: 'assistant' }, finish_reason: null }]
  });

  const content = (text && text.length) ? text : 'OK';
  const chunks = content.match(new RegExp(`.{1,${STREAM_CHUNK_SIZE}}`,'g')) || [];
  for (const ch of chunks) {
    out({
      id: streamId,
      object: 'chat.completion.chunk',
      created: Math.floor(Date.now()/1000),
      model,
      choices: [{ index: 0, delta: { content: ch }, finish_reason: null }]
    });
    // eslint-disable-next-line no-await-in-loop
    await new Promise(r => setTimeout(r, STREAM_DELAY_MS));
  }
  out({
    id: streamId,
    object: 'chat.completion.chunk',
    created: Math.floor(Date.now()/1000),
    model,
    choices: [{ index: 0, delta: {}, finish_reason: 'stop' }]
  });
  res.write('data: [DONE]\n\n');
  res.end();
}

// OpenAI-compatible endpoint
app.post('/v1/chat/completions', async (req,res)=>{
  if (!NOVITA_KEY) return res.status(500).json({ error:'NOVITA_API_KEY missing' });

  const { model, messages, stream, temperature, max_tokens } = req.body || {};
  const normalizedPublic = normalizeIncoming(model);
  const upstreamModel = mapToUpstream(normalizedPublic);
  const msgs = buildMessages({ messages, prompt: undefined });
  if (!msgs) return res.status(400).json({ error:'messages required' });

  const upstreamPayload = {
    model: upstreamModel,
    messages: msgs,
    temperature: typeof temperature === 'number' ? temperature : 0.7,
    max_tokens: typeof max_tokens === 'number' ? max_tokens : 512
  };

  log('OpenAI chat completions -> Novita', { requestedModel: model, normalizedPublic, upstreamModel, stream: !!stream });

  const result = await callNovitaChatCompletion(upstreamPayload);
  if (!result.ok) {
    log('Novita upstream attempts (all failed):', result.attempts);
    return res.status(502).json({ error:{ message:'novita_upstream_error', attempts: result.attempts } });
  }
  const data = result.data;
  const completionText = data?.choices?.[0]?.message?.content ?? '';
  log('Upstream non-stream OK', { empty: !completionText, url: result.url });

  if (stream) {
    return sendSimulatedSSE({ res, model: normalizedPublic, text: completionText });
  }

  return res.json({
    id: 'chatcmpl_' + Math.random().toString(36).slice(2),
    object: 'chat.completion',
    created: Math.floor(Date.now()/1000),
    model: normalizedPublic,
    choices: [{
      index: 0,
      message: { role: 'assistant', content: completionText || 'OK' },
      finish_reason: 'stop'
    }],
    usage: { prompt_tokens: null, completion_tokens: null, total_tokens: null }
  });
});

// Endpoint generik
app.post('/api/generate', async (req,res)=>{
  if (!NOVITA_KEY) return res.status(500).json({ error:"NOVITA_API_KEY missing" });

  const { prompt, messages, stream, model, options } = req.body || {};
  const msgs = buildMessages({ prompt, messages });
  if (!msgs) return res.status(400).json({ error:"prompt or messages required" });

  const normalizedPublic = normalizeIncoming(model);
  const upstreamModel = mapToUpstream(normalizedPublic);
  const temperature = options?.temperature ?? 0.7;
  const max_tokens  = options?.max_tokens ?? 512;

  const result = await callNovitaChatCompletion({ model: upstreamModel, messages: msgs, temperature, max_tokens });
  if (!result.ok) {
    log('Generate non-stream failed:', result.attempts);
    return res.status(502).json({ error: 'novita_upstream_error', attempts: result.attempts });
  }
  const data = result.data;
  const completionText = data?.choices?.[0]?.message?.content ?? '';

  if (stream) {
    return sendSimulatedSSE({ res, model: normalizedPublic, text: completionText });
  }

  return res.json({
    model: PUBLIC_MODEL,
    upstream_model: upstreamModel,
    created_at: new Date().toISOString(),
    response: completionText || 'OK',
    done: true
  });
});

app.use((err,_req,res,_next)=>{
  log('Unhandled middleware error', err);
  res.status(500).json({ error:'unhandled', message:String(err) });
});

app.listen(PORT, ()=>{
  log(`Listening on http://0.0.0.0:${PORT}`);
  log(`Public model: ${PUBLIC_MODEL}`);
  log(`Upstream base: ${UPSTREAM_BASE_MODEL}`);
  log(`Aliases: ${ALIASES.join(', ')}`);
  log(`Novita endpoints (priority): ${NOVITA_OPENAI_ENDPOINTS.join('  |  ')}`);
});