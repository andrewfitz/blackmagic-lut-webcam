// Round 3 builders. Pages call these inline before kit.js renders icons and pictures.

const FEEDS = {
  f1: { n: 1, name: 'Feed 1', cam: 'FX3 · Mini Recorder 12G', fmt: '2160p 59.94', scene: 'mcu', tone: '709',
    rec: { state: 'rec', t: '12:31', size: '18.4 GB', rate: '184 Mb/s', drops: 0 }, folder: '8TB › Takes › Feed 1', left: '1 h 35 m',
    fx: [1, 1, 1, 0], lut: 'FX3_SLog3_to_709', audio: [64, 60, '−9.8'], tools: [1, 1, 0, 0, 0], fxview: 'guides', signal: 'Output' },
  f2: { n: 2, name: 'Feed 2', cam: 'A7S III · UltraStudio 4K Mini', fmt: '2160p 29.97', scene: 'wide', tone: '709',
    rec: { state: 'rec', t: '12:31', size: '9.1 GB', rate: '92 Mb/s', drops: 0 }, folder: 'Archive › B-cam', left: '5 h 40 m', own: true,
    fx: [0, 1, 1, 0], lut: null, audio: [40, 38, '−21.4'], tools: [0, 0, 0, 0, 1], fxview: '', signal: 'Output' },
};
const FX_NAMES = ['LUT', '1080p', '4:2:0', '29.97'];
const TOOL_ICONS = ['guides', 'zebra', 'falsecolor', 'focus', 'scope'];
const ic = (n, cls = 'sm', style = '') => `<i data-i="${n}" class="${cls}"${style ? ` style="${style}"` : ''}></i>`;
const newtag = '<span class="newtag">NEW</span>';

function fxChips(f, small) {
  const st = small ? ' style="height:17px;padding:0 5px;font-size:9.5px"' : '';
  return `<div class="fx">${f.fx.map((on, i) => `<span class="${on ? 'on' : ''}"${st}>${FX_NAMES[i]}</span>`).join('')}</div>`;
}
function meter(f) {
  return `<div class="meter" style="flex:1">L<div class="bar"><i style="width:${f.audio[0]}%"></i><b style="left:${f.audio[0] + 14}%"></b></div></div>
    <div class="meter" style="flex:1">R<div class="bar"><i style="width:${f.audio[1]}%"></i><b style="left:${f.audio[1] + 14}%"></b></div></div>
    <span class="c2 tnum" style="font-size:11px;width:52px;text-align:right">${f.audio[2]} dB</span>`;
}

// role: 'air' | 'next' | null (Program mode) ; mode: 'program' | 'separate'
function tile(f, { role = null, mode = 'program', consumer = null, height = null, compact = false } = {}) {
  const roleBadge = role === 'air' ? `<span class="role air">ON AIR · Program</span>`
    : role === 'next' ? `<span class="role nxt">NEXT</span>` : consumer ? `<span class="role air">ON AIR · ${consumer}</span>` : '';
  const rec = f.rec.state === 'rec' ? `<span class="pill sm glass"><span class="dot red"></span><span class="tnum">REC ${f.rec.t}</span></span>` : '';
  return `<div class="picture ${role === 'air' || consumer ? 'onair' : role === 'next' ? 'next' : ''}" data-scene="${f.scene}" data-tone="${f.tone}" data-fx="${f.fxview}"${height ? ` style="height:${height}px;aspect-ratio:auto"` : ''}>
    <div class="overlay" style="left:10px; top:10px;">${mode === 'program' ? `<span class="kk">${f.n}</span>` : ''}<div class="pill glass">${f.name}${ic('chevud')}</div>${roleBadge}</div>
    <div class="overlay" style="right:10px; top:10px;">${compact ? '' : `<div class="tb-group glass" style="height:30px">${TOOL_ICONS.map((t, i) => `<div class="tb-btn${f.tools[i] ? ' on' : ''}" style="height:24px;min-width:28px">${ic(t)}</div>`).join('')}</div>`}</div>
    <div class="overlay" style="left:10px; bottom:10px;"><span class="pill sm glass mono">14:22:31:12</span><span class="pill sm glass">${f.signal}${ic('chevud')}</span></div>
    <div class="overlay" style="right:10px; bottom:10px;">${rec}</div>
  </div>`;
}

function strip(f, { expanded = true, role = null, mode = 'program', consumer = null } = {}) {
  const recBtn = f.rec.state === 'rec' ? 'recbtn on' : 'recbtn';
  const programCell = mode === 'program'
    ? (role === 'air' ? `<span class="badge red">On air in Program</span>` : `<span class="btn">${ic('cut')}Cut to ${f.name}<span class="c3" style="margin-left:4px">⌃${f.n}</span></span>`)
    : `${ic('camlink', 'sm', consumer ? 'color:var(--green)' : '')}<span>Ultracam · ${f.name}</span><span class="${consumer ? 'cg' : 'c2'}" style="font-size:11px">${consumer ? 'In use by ' + consumer : 'Not in use'}</span>`;
  if (!expanded) {
    return `<div class="strip3 collapsed"><div class="r">
      <span class="chev">${ic('chevr')}</span><b>${f.name}</b>
      ${mode === 'program' && role === 'air' ? '<span class="badge red">On air</span>' : mode === 'program' && role === 'next' ? '<span class="badge green">Next</span>' : ''}
      ${f.rec.state === 'rec' ? `<span class="dot red"></span><span class="tnum">${f.rec.t}</span><span class="c2 tnum" style="font-size:11px">${f.rec.size}</span>` : '<span class="c2">Not recording</span>'}
      ${f.rec.drops ? `<span class="co" style="font-size:11px">${f.rec.drops} dropped</span>` : ''}
      <span style="flex:1"></span>
      ${fxChips(f, true)}
      <div class="minimeter"><div class="meter"><div class="bar"><i style="width:${f.audio[0]}%"></i></div></div><div class="meter"><div class="bar"><i style="width:${f.audio[1]}%"></i></div></div></div>
      <div class="${recBtn} sm"></div>
      <span class="btn icon">${ic('ellipsis')}</span>
    </div></div>`;
  }
  return `<div class="strip3">
    <div class="r"><span class="chev">${ic('chevd')}</span><b style="font-size:13.5px">${f.name}</b><span class="c2" style="font-size:11.5px">${f.cam}</span>
      <span class="badge green">Live · ${f.fmt}</span><span style="flex:1"></span>
      <span class="btn icon">${ic('ellipsis')}</span></div>
    <div class="sep3"></div>
    <div class="r"><div class="${recBtn} sm"></div>
      <div style="display:flex;flex-direction:column;gap:2px"><span class="k2" style="color:#ff6961">Recording</span><span class="elapsed tnum">00:${f.rec.t}</span></div>
      <div style="display:flex;flex-direction:column;gap:2px;margin-left:4px" class="tnum"><span>${f.rec.size} · ${f.rec.rate}</span><span class="cg" style="font-size:11px">0 dropped</span></div>
      <span style="flex:1"></span><span class="btn">${ic('pause')}Pause</span><span class="btn">${ic('stop')}Stop</span></div>
    <div class="r" style="font-size:11.5px">${ic('folder', 'sm c2')}<span>${f.folder}</span><span class="c2 tnum">· ${f.left} left</span>${f.own ? '<span class="badge" style="height:16px">Own folder</span>' : ''}
      <span style="flex:1"></span><span class="c3" style="font-size:11px">ProRes 422 · clean source</span></div>
    <div class="sep3"></div>
    <div class="r">${programCell}<span style="flex:1"></span>${fxChips(f)}<div class="switch sm on"></div></div>
    <div class="r" style="gap:8px"><span class="k2" style="width:40px">Audio</span>${meter(f)}</div>
  </div>`;
}

function sidebar({ mode = 'program', feeds = ['f1', 'f2'], consumer = 'Zoom' } = {}) {
  const camRows = feeds.map((k, i) => {
    const f = FEEDS[k];
    const tally = mode === 'program' ? (i === 0 ? '<span class="dot red"></span>' : '<span class="dot green"></span>') : '<span class="dot green"></span>';
    return `<div class="mini-row" style="${i === 0 ? 'background:rgba(255,255,255,0.08);border-radius:9px' : ''}">${tally}<div style="flex:1;line-height:1.25"><b style="font-weight:600">${f.name}</b><small>${f.fmt} · REC ${f.rec.t}</small></div>${mode === 'program' ? `<span class="c3" style="font-size:11px">⌃${f.n}</span>` : ''}</div>`;
  }).join('');
  const output = mode === 'program' ? `
    <div class="mini-row">${ic('camlink', '', 'color:var(--green)')}<div style="flex:1;line-height:1.25"><b style="font-weight:600">Ultracam · Program</b><small class="cg">In use by ${consumer}</small></div></div>
    <div class="mini-row"><span style="flex:1">Auto switching</span><div class="switch sm on"></div></div>
    <div class="mini-row" style="padding-top:0"><span class="popup plain" style="width:100%;justify-content:space-between">Natural talking head<span class="chev">${ic('chevud')}</span></span></div>
    <div style="padding:4px 8px 2px">
      <div style="display:flex;justify-content:space-between;font-size:10.5px" class="c2 tnum"><span>Feed 1 · 8.2 s</span><span>cut after 10 s</span></div>
      <div class="shot" style="margin-top:5px"><i style="width:27%"></i><span class="mk" style="left:33.3%"></span><span class="mk" style="left:66.6%"></span><span class="mk" style="left:100%;background:var(--red)"></span></div>
    </div>`
    : `<div class="mini-row">${ic('camlink', '', 'color:var(--green)')}<div style="flex:1;line-height:1.25"><b style="font-weight:600">Ultracam · Feed 1</b><small class="cg">In use by ${consumer}</small></div></div>`;
  return `<div class="sidebar glass sb3">
    <div style="position:absolute; top:20px; left:18px;" class="traffic"><span></span><span></span><span></span></div>
    <div style="position:absolute; top:12px; right:10px;" class="tb-btn">${ic('sidebar', '')}</div>
    <div class="side-h" style="display:flex;justify-content:space-between;align-items:center">Cameras${ic('plus', 'sm c2')}</div>
    ${camRows}
    <div class="side-h">Output</div>${output}
    <div class="side-h">Recording</div>
    <div class="mini-row"><span class="dot red"></span><div style="flex:1;line-height:1.25"><b style="font-weight:600">Backup · ${feeds.length} feed${feeds.length > 1 ? 's' : ''}</b><small class="tnum">12:31 · ${feeds.length > 1 ? '27.5' : '18.4'} GB · ProRes 422</small></div></div>
    <div style="padding:3px 8px 2px;display:flex;flex-direction:column;gap:4px">
      <div style="display:flex;align-items:center;gap:6px;font-size:11px">${ic('folder', 'sm c2')}8TB${newtag}<span class="c2 tnum" style="margin-left:auto">${feeds.length > 1 ? '1 h 35 m' : '3 h 10 m'} left</span></div>
      <div class="gauge"><i style="width:74%"></i></div>
    </div>
    <div class="side-h" style="display:flex;justify-content:space-between">Recent Takes${newtag}</div>
    <div class="take">${ic('video', 'sm c2')}<div style="flex:1"><span>Today 08:02<span class="c2"> · 38:12</span></span><small>Feed 1_2026-10-20_08-02-11_001.mov</small></div></div>
    <div class="take" style="background:rgba(255,159,10,0.10)">${ic('info', 'sm co')}<div style="flex:1"><span class="co">Interrupted</span><small>Oct 19 11:15</small></div><span class="btn" style="height:20px;font-size:11px">Recover</span></div>
    <div class="side-h">Automation</div>
    <div class="mini-row" style="padding:2px 8px"><span style="flex:1">Start with camera apps</span><div class="switch sm on"></div></div>
    <div class="mini-row" style="padding:2px 8px"><span style="flex:1">Record with camera apps${newtag}</span><div class="switch sm on"></div></div>
  </div>`;
}

function toolbar({ title, subtitle, layout = 'split', mode = 'program', collapsedAll = false, left = 252, recLabel = '12:31 · 2' }) {
  const lay = [['single', 'Single'], ['split', 'Side by Side'], ['program', 'Program view'], ['grid', 'Four Up']]
    .filter(([k]) => mode === 'program' || k !== 'program')
    .map(([k]) => `<div class="tb-btn${k === layout ? ' on' : ' dim'}">${ic(k, '')}</div>`).join('');
  const cuts = mode === 'program' ? `<div class="tb-group glass">
      <div class="tb-btn" style="background:rgba(255,69,58,0.88);color:#fff"><span class="kk" style="width:16px;height:16px;font-size:10px;background:rgba(255,255,255,0.25)">1</span>Feed 1</div>
      <div class="tb-btn" style="box-shadow:inset 0 0 0 1.5px var(--green)"><span class="kk" style="width:16px;height:16px;font-size:10px">2</span>Feed 2</div>
      <div class="tb-sep"></div><div class="tb-btn on">${ic('auto')}Auto</div></div>` : '';
  return `<div class="toolbar" style="left:${left}px; right:8px; padding-left:${left > 100 ? 4 : 18}px;">
    ${left < 100 ? '<div class="traffic" style="margin-right:8px"><span></span><span></span><span></span></div><div class="tb-group glass">' + `<div class="tb-btn">${ic('sidebar', '')}</div></div>` : ''}
    <div class="title"><b>${title}</b><small>${subtitle}</small></div>
    <div class="flex"></div>
    ${cuts}
    <div class="tb-group glass">${lay}</div>
    <div class="tb-group glass"><div class="tb-btn${collapsedAll ? ' on' : ''}" title="Collapse strips">${ic('sliders', '')}</div></div>
    <div class="tb-prominent red">${ic('stop')}<span class="tnum">${recLabel}</span></div>
  </div>`;
}

function statusbar({ mode = 'program', consumer = 'Zoom', feeds = 2 }) {
  return `<div class="sbar tnum">
    <div class="seg2 hover cg">${ic('camlink')}${mode === 'program' ? 'Ultracam · Program' : 'Ultracam · Feed 1'} → ${consumer}</div>
    ${mode === 'program' ? `<div class="div"></div><div class="seg2">${ic('program')}Feed 1 on air · Auto</div>` : ''}
    <div class="div"></div>
    <div class="seg2"><span class="dot red" style="box-shadow:none"></span><span style="color:var(--label)">REC ${feeds > 1 ? '2 feeds ' : ''}12:31</span> · 8TB ${feeds > 1 ? '1 h 35 m' : '3 h 10 m'} left${newtag}</div>
    <div class="div"></div>
    <div class="seg2">${ic('wave')}Audio OK</div>
    <div class="sp"></div>
    <div class="seg2">CPU ${feeds > 1 ? '48.6' : '31.4'}% · GPU (video) ${feeds > 1 ? '29.8' : '18.2'}% · Memory ${feeds > 1 ? '1.71' : '1.08'} GB</div>
  </div>`;
}

function mount(id, html) { document.getElementById(id).innerHTML = html; }
