// TDD (written BEFORE the chat-format.js changes): pins the Expansion chat-line format from REAL box
// lines + the requested "day divider + IRC" render. Run: node --test js/chat-format.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseChatLine, chatDateFromLogName, renderChatLine, renderChatDay } from './chat-format.js';

const REAL = '02:59:31.093 [Chat - Global]("Cryptkeeper"(id=T6jz4wcp7EuQa5YfSTjeM2FfuSbW2tGK0Mm3aTISZcw=)): any food you guys can spare';
const ESC = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));

test('parseChatLine pulls time/channel/name/id/msg from a real Expansion chat line', () => {
  assert.deepEqual(parseChatLine(REAL), {
    time: '02:59:31', channel: 'Global', name: 'Cryptkeeper',
    id: 'T6jz4wcp7EuQa5YfSTjeM2FfuSbW2tGK0Mm3aTISZcw=', msg: 'any food you guys can spare',
  });
});

test('parseChatLine returns null for non-chat lines', () => {
  assert.equal(parseChatLine(' SCRIPT       : DZ_Expansion_Chat'), null);
  assert.equal(parseChatLine('12:00:00.000 [Login]("x"(id=a=)): hi'), null);   // not a Chat channel
  assert.equal(parseChatLine(''), null);
});

test('parseChatLine keeps a message that contains ) : quotes and colons', () => {
  const r = parseChatLine('10:00:00.000 [Chat - Side]("Bob"(id=abc=)): lol :) "hi" (test): ok');
  assert.equal(r.name, 'Bob'); assert.equal(r.channel, 'Side'); assert.equal(r.msg, 'lol :) "hi" (test): ok');
});

test('chatDateFromLogName reads the date out of an ExpLog filename', () => {
  assert.equal(chatDateFromLogName('ExpLog_2026-07-29_00-59-52.log'), '2026-07-29');
  assert.equal(chatDateFromLogName('script_2026-07-28.log'), null);
});

test('renderChatLine (IRC): [time] <name> msg — no date on the line, dim [time], id on hover', () => {
  const html = renderChatLine(REAL, ESC);
  assert.match(html, /class="chat-ts"[^>]*>\[02:59:31\]/);                  // dim [time] only — date lives in the divider
  assert.ok(!/\d{4}-\d{2}-\d{2}/.test(html), 'the date must NOT appear on the line');
  assert.match(html, /class="chat-name"[^>]*>Cryptkeeper/);                 // emphasized name
  const visible = html.replace(/<[^>]*>/g, '')                             // strip tags, then decode entities
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');    // -> what the eye actually sees
  assert.ok(visible.includes('<Cryptkeeper>'), 'name wears IRC angle brackets');
  assert.match(html, /class="chat-msg"[^>]*>any food you guys can spare/);  // message
  assert.ok(!visible.includes('T6jz4wcp7'), 'the id hash must not be visible inline');
  assert.match(html, /title="[^"]*T6jz4wcp7/);                             // id available on hover (title attr)
});

test('renderChatLine hides the channel tag for Global, shows it otherwise', () => {
  assert.ok(!renderChatLine(REAL, ESC).includes('chat-ch'), 'Global is the default channel — no tag');
  const side = renderChatLine('10:00:00.000 [Chat - Side]("Bob"(id=abc=)): hey', ESC);
  assert.match(side, /class="chat-ch"[^>]*>\[Side\]/);                      // non-Global channel shown
  assert.match(side, /class="chat-name"[^>]*>Bob/);
});

test('renderChatLine escapes HTML in the message', () => {
  const html = renderChatLine('01:02:03.000 [Chat - Global]("Eve"(id=z=)): <script>x</script> & y', ESC);
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(!html.includes('<script>x'));
});

test('renderChatLine returns null for a non-chat line (caller falls back to normal render)', () => {
  assert.equal(renderChatLine(' SCRIPT : boot', ESC), null);
});

test('renderChatDay renders a dated divider row', () => {
  const html = renderChatDay('2026-07-29', ESC);
  assert.match(html, /chat-day/);                    // its own row class
  assert.match(html, /2026-07-29/);                  // the date
  assert.match(html, /─/);                           // rule dashes
});

test('renderChatDay returns empty string when there is no date', () => {
  assert.equal(renderChatDay(null, ESC), '');
  assert.equal(renderChatDay('', ESC), '');
});
