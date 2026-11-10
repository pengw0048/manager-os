#!/usr/bin/env node
// Stand-in for `claude -p` in tests: answers by schema shape, logs each call to $FAKE_CLAUDE_LOG.
import { appendFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const args = process.argv.slice(2);
const arg = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const schema = JSON.parse(arg('--json-schema') || '{}');
const resume = arg('--resume');
let prompt = '';
process.stdin.on('data', (d) => (prompt += d));
process.stdin.on('end', () => {
  if (process.env.FAKE_CLAUDE_LOG) appendFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ args, resume, prompt }) + '\n');
  if (process.env.FAKE_CLAUDE_FAIL_RESUME && resume) { process.stderr.write('No conversation found with session ID: ' + resume); process.exit(1); }
  const props = Object.keys(schema.properties || {});
  let out;
  if (props.includes('brief')) {
    const ids = [...prompt.matchAll(/Context item (a_\w+)/g)].map((m) => m[1]);
    const urgent = /incident|outage|P0/i.test(prompt);
    out = {
      title_en: 'Fake title', title_zh: '假标题', brief: '## 请求\n做这件事。',
      urgency: urgent ? 'P0' : 'P2', urgency_reason: urgent ? '事故' : '普通',
      status: (prompt.match(/STATUS:(\w+)/g) || ['STATUS:needs_me']).pop().slice(7), status_reason: '原因',
      due_at: null, requester: null, artifact_summaries: ids.map((id) => ({ id, summary: `摘要 ${id}` })),
    };
  } else if (props.includes('assignments')) {
    const items = [...prompt.matchAll(/### Item (s_\w+)/g)].map((m) => m[1]);
    const topic = (prompt.match(/- (t_\w+):/) || [])[1] || '';
    out = { assignments: items.map((id, i) => {
      const body = (prompt.split(`### Item ${id}`)[1] || '').split('### Item')[0];
      const action = /thanks/i.test(body) ? 'skip' : i === 0 && topic ? 'existing' : 'new';
      return { item_id: id, action, topic_id: action === 'existing' ? topic : '', title_en: `New ${i}`, title_zh: `新 ${i}`, reason: '理由' };
    }) };
  } else if (props.includes('overview')) {
    out = { overview: '- 概览' };
  } else if (props.includes('hits')) {
    const sys = arg('--system-prompt') || '';
    const q = prompt.replace(/^Query:\s*/, '').trim().toLowerCase();
    const line = sys.split('\n').find((l) => /^- t_\w+/.test(l) && l.toLowerCase().includes(q.split(' ')[0])) || sys.split('\n').find((l) => /^- t_\w+/.test(l));
    const id = line ? line.match(/^- (t_\w+)/)[1] : null;
    out = { answer: '', hits: id ? [{ topic_id: id, reason: '匹配' }] : [] };
  } else if (props.includes('topic_links')) {
    const id = (prompt.match(/- (t_\w+):/) || [])[1] || '';
    out = { reply: '给你。', topic_links: id ? [id] : [], actions: /follow/i.test(prompt) && id ? [{ type: 'set_followup', topic_id: id, text_en: 'Follow up tomorrow', text_zh: '明天跟进', value: '2030-01-01' }] : [] };
  } else {
    const msg = (prompt.split('## Her message\n')[1] || '').trim();
    const m = msg.match(/^add to timeline:\s*(.+)/i);
    out = {
      reply: m ? '已添加。' : '回答。',
      actions: m ? [{ type: 'add_timeline', text_en: m[1], text_zh: m[1], value: '' }] : /status/i.test(msg) ? [{ type: 'set_status', text_en: 'Set waiting', text_zh: '改为等别人', value: 'waiting' }] : [],
    };
  }
  process.stdout.write(JSON.stringify({
    type: 'result', subtype: 'success', is_error: false, result: JSON.stringify(out), structured_output: out,
    session_id: resume || randomUUID(), duration_ms: 5, total_cost_usd: 0.01,
    usage: { input_tokens: 10, output_tokens: 20, cache_read_input_tokens: 1000, cache_creation_input_tokens: 500 },
  }));
});
