// dom.js — the single cache of element references, resolved once at module load. Modules
// load deferred, so the DOM is fully parsed by the time `el` is built. Every module reads
// elements through `el`; `$` is the getElementById shorthand. Extracted from index.html.
export const $ = (id) => document.getElementById(id);

export const el = {
  login: $('login'), loginForm: $('loginForm'), keyId: $('keyId'), secret: $('secret'),
  connect: $('connect'), loginMsg: $('loginMsg'),
  app: $('app'), tabs: $('tabs'), tabMaint: $('tabMaint'), tabFiles: $('tabFiles'), tabApi: $('tabApi'), tabMap: $('tabMap'), tabLogs: $('tabLogs'), tabDocs: $('tabDocs'),
  maintNav: $('maintNav'), mntNavRole: $('mntNavRole'), mntNavSummary: $('mntNavSummary'),
  mainttab: $('mainttab'), mntRole: $('mntRole'), mntRefresh: $('mntRefresh'), mntViewerNote: $('mntViewerNote'), mntDot: $('mntDot'),
  mntStatusBody: $('mntStatusBody'), mntHostBody: $('mntHostBody'), mntPlayersBody: $('mntPlayersBody'),
  mntUpdateInfo: $('mntUpdateInfo'), mntUpdQueue: $('mntUpdQueue'), mntUpdCancel: $('mntUpdCancel'), mntUpdLogWrap: $('mntUpdLogWrap'), mntUpdLog: $('mntUpdLog'),
  mntArm: $('mntArm'), mntStart: $('mntStart'), mntRestart: $('mntRestart'), mntStop: $('mntStop'), mntForce: $('mntForce'),
  mntMapSel: $('mntMapSel'), mntMapGo: $('mntMapGo'), mntMsg: $('mntMsg'), mntSend: $('mntSend'),
  signout: $('signout'), toast: $('toast'), themeToggle: $('themeToggle'),
  statsbar: $('statsbar'), sbStats: $('sbStats'), sbArm: $('sbArm'), sbRestart: $('sbRestart'),
  sbUpdate: $('sbUpdate'), sbUpdPill: $('sbUpdPill'), sbUpdQueue: $('sbUpdQueue'), sbUpdCancel: $('sbUpdCancel'), updPanel: $('updPanel'),
  filesNav: $('filesNav'), apiNav: $('apiNav'), mapNav: $('mapNav'), logsNav: $('logsNav'), docsNav: $('docsNav'),
  logSource: $('logSource'), logDate: $('logDate'), logDateRow: $('logDateRow'), logFileSel: $('logFileSel'), logNavMeta: $('logNavMeta'),
  logstab: $('logstab'), logFilter: $('logFilter'), logCase: $('logCase'), logRe: $('logRe'), logGoto: $('logGoto'),
  logStatus: $('logStatus'), logFollow: $('logFollow'), logRefresh: $('logRefresh'),
  logPane: $('logPane'), logEmpty: $('logEmpty'), logLines: $('logLines'),
  workspace: $('workspace'),
  editorPage: $('editorPage'), edEmpty: $('edEmpty'), edEditor: $('edEditor'), ovrVersions: $('ovrVersions'),
  ownfile: $('ownfile'), ownPath: $('ownPath'), ownTa: $('ownTa'), ownSave: $('ownSave'),
  apitab: $('apitab'), swagger: $('swagger'), docstab: $('docstab'), docView: $('docView'), docsHead: $('docsHead'),
  maptab: $('maptab'), mapSel: $('mapSel'), mapRefresh: $('mapRefresh'), mapSum: $('mapSum'),
  mapStage: $('mapStage'), mapCanvas: $('mapCanvas'), mapEmpty: $('mapEmpty'), mapBar: $('mapBar'),
  mapLayerSeg: $('mapLayerSeg'), mapGridSeg: $('mapGridSeg'), mapDetail: $('mapDetail'), mapTip: $('mapTip'), mapFilter: $('mapFilter'),
  mapLootFilter: $('mapLootFilter'), mapSpawnFilter: $('mapSpawnFilter'), mapBuildingsFilter: $('mapBuildingsFilter'), mapMarkersFilter: $('mapMarkersFilter'), mapLiveFilter: $('mapLiveFilter'),
  mapEditSeg: $('mapEditSeg'), mapSaveWrap: $('mapSaveWrap'), mapSaveBtn: $('mapSaveBtn'), mapDiscardBtn: $('mapDiscardBtn'), mapCalBtn: $('mapCalBtn'),
};
