// The live overlays as DATA, not as three copies of the same code.
//
// Players, AI and the ship each used to carry their own colour branch, count branch, status
// branch and draw function - the word 'NPCs' alone appeared in six places, so a fourth overlay
// meant six edits plus a renderer copied from an old one. They differ in exactly three ways:
// where the positions come from, what the marker looks like, and what the status bar says. Those
// are fields here; everything else is shared.
//
// No DOM in this module, so the rules can be tested by calling them.

// marker: how one position is drawn. The canvas code owns the pixels; this owns the choice.
export const LIVE_LAYERS = [
  {
    key: 'Players',
    cssVar: '--info', fallback: '#2f6fd0',
    marker: 'circle',
    pick: false,                       // players are anonymised - there is nothing to open
    source: 'players',
    // What the status bar says for this layer, as DATA - the bar renders it the same way for
    // every layer, so wording lives with the layer instead of in a branch inside the bar.
    badge: (pos, meta) => (pos.length
      ? { text: pos.length + ' player' + (pos.length === 1 ? '' : 's') + (meta.at ? ' \u00b7 as of ' + meta.at : ''),
          title: 'Live player positions (anonymised), updated every 20s' }
      : null),
  },
  {
    key: 'NPCs',
    cssVar: '--map-bad', fallback: '#c33327',
    marker: 'diamond',
    pick: true,                        // click one to see what the tracker knows about it
    source: 'ai',
    badge: (pos, meta) => (pos.length
      ? { text: pos.length + ' AI', title: 'Live AI positions from the LiveTracker serverMod, updated every 20s' }
      : meta.stale
        ? { text: 'AI tracker stale', stale: true, title: 'No update in over a minute - the server or the tracker serverMod may be down' }
        : null),
  },
  {
    key: 'Ship',
    cssVar: '--map-ship', fallback: '#0e9aa7',
    marker: 'ship',
    pick: false,
    source: 'ship',
    badge: (pos, meta) => (pos.length
      ? { text: '\u26f5 ' + (pos[0].state || '?') + (pos[0].target ? ' \u2192 ' + pos[0].target : ''),
          title: 'The Flying Dutchman - live position from the serverMod, updated every 20s' }
      : meta.stale
        ? { text: 'ship tracker stale', stale: true, title: 'No update in over a minute - the server or the FlyingDutchman serverMod may be down' }
        : null),
  },
];

export const LIVE_KINDS = LIVE_LAYERS.map((l) => l.key);
export function liveLayer(key) { return LIVE_LAYERS.find((l) => l.key === key) || null; }

// Every live overlay answers the same two questions before it draws or counts:
//   - is this the map the server is actually running? live coordinates mean nothing on another
//     map, so plotting them there would be fiction;
//   - has the operator left the layer on?
// A stale feed arrives with no positions at all, so staleness needs no gate here.
export function liveVisible(layer, { onLiveMission, selected }) {
  if (!layer) return false;
  return !!onLiveMission && !!selected;
}

// Positions for a layer, from one bag of live state keyed by `source`. Missing or malformed
// state reads as empty rather than throwing: a poller that has not run yet is normal.
export function livePositions(layer, state) {
  if (!layer || !state) return [];
  const v = state[layer.source];
  return Array.isArray(v) ? v : [];
}

export function liveCount(layer, state, { onLiveMission } = { onLiveMission: true }) {
  if (!onLiveMission) return 0;
  return livePositions(layer, state).length;
}
