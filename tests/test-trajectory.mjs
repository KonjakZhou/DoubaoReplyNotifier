import crypto from 'node:crypto';

const waitingTools = new Set([
  'interaction.ask', 'interaction_ask',
  'interaction.request_action', 'interaction_request_action',
  'interaction.authorize_folder', 'interaction_authorize_folder'
]);

function waitingEvent(line, conversationId) {
  const record = JSON.parse(line);
  if (record.role !== 'assistant') return null;
  const names = new Set((record.tool_calls || []).map(call => call.function?.name).filter(Boolean));
  const waitingTool = [...names].find(name => waitingTools.has(name));
  if (!waitingTool) return null;
  return {
    type: 'waiting_user',
    source: `trajectory:${waitingTool}`,
    eventId: `${conversationId}|waiting_user|${crypto.createHash('sha256').update(line).digest('hex')}`
  };
}

const ordinaryText = JSON.stringify({role:'assistant', content:'请确认结果；等待你查看', tool_calls:[{function:{name:'Read'}}]});
const noToolFinal = JSON.stringify({role:'assistant', content:'测试消息'});
const ask = JSON.stringify({role:'assistant', content:'请选择', tool_calls:[{function:{name:'interaction.ask'}}]});
const requestAction = JSON.stringify({role:'assistant', content:'请接管', tool_calls:[{function:{name:'interaction_request_action'}}]});

if (waitingEvent(ordinaryText, '90000000000000001') !== null) throw new Error('ordinary text incorrectly triggered waiting');
if (waitingEvent(noToolFinal, '90000000000000001') !== null) throw new Error('assistant final incorrectly used as completion signal');
const events = [ask, requestAction].map(line => waitingEvent(line, '90000000000000001'));
if (events.some(event => event?.type !== 'waiting_user')) throw new Error('explicit interaction tool not recognized');
if (new Set(events.map(event => event.eventId)).size !== 2) throw new Error('waiting event IDs are not unique');

console.log(JSON.stringify({
  source: 'main-agent trajectory.jsonl',
  responsibility: 'explicit waiting-user signals only',
  waitingEvents: events.length,
  ordinaryTextFalsePositive: false,
  assistantFinalUsedForCompletion: false,
  domSignalsUsed: false
}, null, 2));
