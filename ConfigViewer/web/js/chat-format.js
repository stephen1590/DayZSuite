// Format Expansion chat lines from the ExpansionMod log for the Logs tab's Chat view. The line
// carries only a time; the DATE comes from the log filename (ExpLog_YYYY-MM-DD_...). Real line
// shape:
//   HH:MM:SS.mmm [Chat - <Channel>]("<Name>"(id=<hash>)): <message>
const CHAT_RE = /^(\d{2}:\d{2}:\d{2})\.\d+ \[Chat - ([^\]]+)\]\("([^"]*)"\(id=([^)]*)\)\): (.*)$/;

export function parseChatLine(line) {
  const m = typeof line === 'string' ? line.match(CHAT_RE) : null;
  return m ? { time: m[1], channel: m[2], name: m[3], id: m[4], msg: m[5] } : null;
}

// The date for a chat line comes from its log file's name, e.g. ExpLog_YYYY-MM-DD_HH-MM-SS.log.
export function chatDateFromLogName(name) {
  const m = typeof name === 'string' ? name.match(/ExpLog_(\d{4}-\d{2}-\d{2})_/) : null;
  return m ? m[1] : null;
}

// Render one chat line as HTML, or null if it is not a chat line (caller renders it normally).
// "Day divider + IRC" format - the DATE is not on the line, it heads its own divider row
// (renderChatDay). The line itself is:  [<time>] [<channel>] <name> <message>
//   - [time] dim, id available on hover; channel tag shown only when it is not the default Global;
//   - name wears IRC angle brackets and is emphasised.
// `escape` is the caller's HTML escaper (keeps this module dependency-free + unit-testable).
export function renderChatLine(line, escape) {
  const c = parseChatLine(line);
  if (!c) return null;
  const esc = escape || ((s) => s);
  const chTag = c.channel && c.channel !== 'Global'
    ? '<span class="chat-ch">[' + esc(c.channel) + ']</span> ' : '';
  return '<span class="chat-ts" title="' + esc(c.id) + '">[' + esc(c.time) + ']</span> '
    + chTag
    + '<span class="chat-sep">&lt;</span>'
    + '<span class="chat-name">' + esc(c.name) + '</span>'
    + '<span class="chat-sep">&gt;</span> '
    + '<span class="chat-msg">' + esc(c.msg) + '</span>';
}

// A day-divider row for the chat view - the date only appears here, once, above its lines.
// Returns '' when there is no date (caller then renders no divider). Shaped like a log row
// (.ll .lt) so it aligns with the lines it heads.
export function renderChatDay(dateStr, escape) {
  if (!dateStr) return '';
  const esc = escape || ((s) => s);
  const rule = '──────────';
  return '<div class="ll chat-day"><span class="ln"></span><span class="lt">'
    + '<span class="chat-day-rule">' + rule + '</span> '
    + '<span class="chat-day-date">' + esc(dateStr) + '</span> '
    + '<span class="chat-day-rule">' + rule + '</span>'
    + '</span></div>';
}
