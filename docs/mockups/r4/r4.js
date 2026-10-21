// Round 4 builders: the round-3 structure with every audit fix (docs/mockups/r3/audit/REPORT.md, D1–D8).
// Pages call these inline before kit.js renders icons, pictures and scopes. Add ?light for the light appearance.

if (location.search.includes('light')) document.documentElement.classList.add('light');

// Recording rates are realistic for ProRes 422 UHD (~ 700 Mb/s at 59.94, ~ 350 Mb/s at 29.97).
const CAMS = {
  c1: { n: 1, name: 'Camera 1', input: 'FX3 · Mini Recorder 12G', fmt: '2160p 59.94', out: '1080p 29.97', scene: 'mcu', tone: '709',
    rec: { state: 'rec', t: '00:12:31', size: '64.2 GB', rate: '707 Mb/s', drops: 0 }, drive: '8TB', folder: '8TB › Takes › Camera 1', left: '1 h 52 m',
    fx: [1, 1, 1, 1], lut: 'FX3_SLog3_to_709', audio: [64, 60, '−9.8'], tools: [1, 1, 0, 0, 0], fxview: '', signal: 'Output' },
  c2: { n: 2, name: 'Camera 2', input: 'A7S III · UltraStudio 4K Mini', fmt: '2160p 29.97', out: '1080p 29.97', scene: 'wide', tone: '709',
    rec: { state: 'rec', t: '00:12:31', size: '32.6 GB', rate: '354 Mb/s', drops: 0 }, drive: 'Archive', folder: 'Archive › B-cam', left: '5 h 40 m', own: true,
    fx: [0, 1, 1, 0], lut: null, audio: [40, 38, '−21.4'], tools: [0, 0, 0, 0, 1], fxview: '', signal: 'Output' },
};
const FX_NAMES = ['LUT', '1080p', '4:2:0', '29.97'];
const FX_HELP = ['Live-safe', 'Changes the camera output format', 'Changes the camera output format', 'Changes the camera output format'];
const TOOL_ICONS = ['guides', 'zebra', 'falsecolor', 'focus', 'scope'];
const ic = (n, cls = 'sm', style = '') => `<i data-i="${n}" class="${cls}"${style ? ` style="${style}"` : ''}></i>`;
const newtag = '<span class="newtag">NEW</span>';

function fxChips(c, { small = false, bypass = false } = {}) {
  return `<div class="fx4${small ? ' sm' : ''}${bypass ? ' bypass' : ''}">${c.fx.map((on, i) =>
    `<span class="${on ? 'on' : ''}" title="${FX_HELP[i]}">${FX_NAMES[i]}</span>`).join('')}</div>`;
}
function meters(c) {
  return `<div class="meter" style="flex:1">L<div class="bar"><i style="width:${c.audio[0]}%"></i><b style="left:${c.audio[0] + 14}%"></b></div></div>
    <div class="meter" style="flex:1">R<div class="bar"><i style="width:${c.audio[1]}%"></i><b style="left:${c.audio[1] + 14}%"></b></div></div>
    <span class="c2 tnum" style="font-size:11px;width:52px;text-align:right">${c.audio[2]} dB</span>`;
}
function miniMeter(c) {
  return `<div class="minimeter"><div class="meter"><div class="bar"><i style="width:${c.audio[0]}%"></i></div></div><div class="meter"><div class="bar"><i style="width:${c.audio[1]}%"></i></div></div></div>`;
}

/* tile(c, opts)
   role: 'air' | 'next' | null (Program). 'air' renders ON AIR only when programInUse, else PROGRAM.
   mode: 'program' | 'separate'; inUse: separate-mode camera has a client (→ ON AIR, no app name).
   state: 'live' | 'nosignal' | 'unsupported' | 'stopped' | 'hidden' | 'updating' | 'paused' | 'recnosignal'
   hover: show the hover controls (tools, signal, timecode, freeze/clean/zoom/detach). selected: accent ring. */
function tile(c, { role = null, mode = 'program', programInUse = true, inUse = false, state = 'live', hover = false, selected = false, height = null, compact = false } = {}) {
  const onAir = (mode === 'program' && role === 'air' && programInUse) || (mode === 'separate' && inUse);
  const roleBadge = mode === 'program' && role === 'air' ? (programInUse ? '<span class="role air">ON AIR</span>' : '<span class="role prog">PROGRAM</span>')
    : mode === 'program' && role === 'next' ? '<span class="role nxt">NEXT</span>' : onAir ? '<span class="role air">ON AIR</span>' : '';
  const ring = onAir ? 'tally-air' : role === 'next' ? 'tally-next' : '';
  const live = !['nosignal', 'unsupported', 'stopped', 'hidden', 'recnosignal'].includes(state);
  let rec = '';
  if (c.rec.state === 'rec' && state !== 'recnosignal') rec = `<span class="pill sm glass recpill"><span class="dot red"></span><span class="tnum">REC ${c.rec.t.replace(/^00:/, '')}</span></span>`;
  if (c.rec.state === 'paused' || state === 'paused') rec = `<span class="pill sm glass"><span class="co">❚❚</span><span class="tnum">Paused ${c.rec.t.replace(/^00:/, '')}</span></span>`;
  if (state === 'recnosignal') rec = `<span class="pill sm glass co">${ic('info')}<span class="tnum">REC · no signal 0:42</span></span>`;
  const ph = {
    nosignal: `<div class="ph">${ic('video', 'lg')}<b>No HDMI signal</b><small>Check the camera's HDMI output: 2160p 29.97 or 59.94, 10-bit 4:2:2, RAW off.</small></div>`,
    recnosignal: `<div class="ph">${ic('video', 'lg')}<b>No HDMI signal</b><small>The take stays open; nothing is written until the signal returns.</small></div>`,
    unsupported: `<div class="ph">${ic('info', 'lg')}<b>1920×1080i 59.94 isn't supported</b><small>Waiting for 2160p 29.97 or 59.94.</small></div>`,
    stopped: `<div class="ph">${ic('video', 'lg')}<b>Camera stopped</b><small>Start the camera to see its HDMI input.</small><span class="btn" style="margin-top:4px">${ic('play')}Start Camera</span></div>`,
    hidden: `<div class="ph">${ic('eye', 'lg')}<b>Preview hidden</b><small>Camera output continues. Hidden previews do no rendering work.</small><span class="btn" style="margin-top:4px">Show Preview</span></div>`,
  }[state] || '';
  const updating = state === 'updating' ? `<div class="overlay" style="left:50%;top:50%;transform:translate(-50%,-50%)"><span class="pill glass">${ic('refresh')}Updating output…</span></div>` : '';
  const showTools = hover && !compact && live;
  return `<div class="picture ${ring}${selected ? ' sel-ring' : ''}" ${live ? `data-scene="${c.scene}" data-tone="${c.tone}" data-fx="${c.fxview}"` : 'style="background:#0b0b0d"'}${height ? ` style="height:${height}px;aspect-ratio:auto"` : ''} aria-label="${c.name}">
    ${ph}${updating}
    <div class="overlay" style="left:10px; top:10px;">${mode === 'program' ? `<span class="kk">${c.n}</span>` : ''}<div class="pill glass">${c.name}${ic('chevud')}</div>${roleBadge}</div>
    ${showTools ? `<div class="overlay" style="right:10px; top:10px;"><div class="tb-group glass" style="height:30px">${TOOL_ICONS.map((t, i) => `<div class="tb-btn${c.tools[i] ? ' on' : ''}" style="height:24px;min-width:28px">${ic(t)}</div>`).join('')}</div></div>` : ''}
    ${showTools ? `<div class="overlay" style="left:10px; bottom:10px;"><span class="pill sm glass mono">14:22:31:12</span><span class="pill sm glass">${c.signal}${ic('chevud')}</span></div>
      <div class="overlay" style="left:50%; bottom:10px; transform:translateX(-50%)"><div class="tb-group glass" style="height:30px"><div class="tb-btn" style="height:24px">${ic('freeze')}</div><div class="tb-btn" style="height:24px">${ic('clean')}</div><div class="tb-btn" style="height:24px;font-size:11px">Fit${ic('chevd')}</div><div class="tb-btn" style="height:24px">${ic('detach')}</div></div></div>` : ''}
    ${!showTools && c.tools.some(Boolean) && live ? `<div class="overlay" style="right:10px; top:10px;">${c.tools.map((on, i) => on ? `<span class="pill sm glass" style="padding:0 7px">${ic(TOOL_ICONS[i])}</span>` : '').join('')}</div>` : ''}
    <div class="overlay" style="right:10px; bottom:10px;">${rec}</div>
  </div>`;
}

/* strip(c, opts)
   state: 'recording' | 'paused' | 'ready' | 'saved' | 'finishing' | 'nofolder' | 'failed' | 'recnosignal' | 'stopped' | 'waiting' | 'updating'
   mode: 'program' | 'separate'; role 'air' | 'next' | null; programInUse; inUse (separate); selected. */
function strip(c, { expanded = true, state = null, role = null, mode = 'program', programInUse = true, inUse = false, selected = false, bypass = false } = {}) {
  state = state || (c.rec.state === 'rec' ? 'recording' : c.rec.state === 'paused' ? 'paused' : 'ready');
  const recOn = state === 'recording' || state === 'recnosignal';
  const tone = state === 'recnosignal' || state === 'nofolder' ? ' warn' : state === 'failed' ? ' err' : '';
  const statusBadge = state === 'stopped' ? '<span class="badge">Stopped</span>' : state === 'waiting' ? '<span class="badge orange">Waiting for HDMI</span>'
    : state === 'recnosignal' ? '<span class="badge orange">No signal</span>'
    : `<span class="badge green">● ${c.fmt}</span>`;
  const roleBadge = mode === 'program' && role === 'air' ? (programInUse ? '<span class="badge red">On air</span>' : '<span class="badge">Program</span>')
    : mode === 'program' && role === 'next' ? '<span class="badge green">Next</span>' : '';
  const recLabel = {
    recording: `<span class="k2" style="color:#ff6961">Recording</span><span class="elapsed tnum">${c.rec.t}</span>`,
    recnosignal: `<span class="k2 co">Recording · no signal 0:42</span><span class="elapsed tnum">${c.rec.t}</span>`,
    paused: `<span class="k2 co">Paused</span><span class="elapsed tnum c2">${c.rec.t}</span>`,
    finishing: `<span class="k2">Finishing…</span><span class="c2" style="font-size:11.5px">Writing the final fragment</span>`,
    saved: `<span class="k2 cg">Saved</span><span style="font-size:11.5px">${c.name}_2026-10-21_09-41-03_001.mov · 38:12</span>`,
    nofolder: `<span class="k2 co">No folder</span><span style="font-size:11.5px">Choose where ${c.name} records</span>`,
    failed: `<span class="k2 cr">Recording stopped</span><span style="font-size:11.5px">The drive was disconnected. Saved up to 00:12:20.</span>`,
    ready: `<span class="k2">Ready to record</span><span class="c2" style="font-size:11.5px">${c.fmt} · ProRes 422</span>`,
    stopped: `<span class="k2">Camera stopped</span><span class="c2" style="font-size:11.5px">Start the camera to record</span>`,
    waiting: `<span class="k2">Waiting for HDMI</span><span class="c2" style="font-size:11.5px">Record becomes available with a signal</span>`,
    updating: `<span class="k2" style="color:#ff6961">Recording</span><span class="elapsed tnum">${c.rec.t}</span>`,
  }[state];
  const recActions = {
    recording: `<span class="btn">${ic('pause')}Pause</span>`, recnosignal: `<span class="btn">${ic('pause')}Pause</span>`, updating: `<span class="btn">${ic('pause')}Pause</span>`,
    paused: `<span class="btn">${ic('play')}Resume</span>`,
    finishing: `<span class="c3" style="font-size:11px">Recording actions are disabled until saved</span>`,
    saved: `<span class="btn">${ic('folder')}Show in Finder</span>`,
    nofolder: `<span class="btn">Choose Folder…</span>`, failed: `<span class="btn">${ic('folder')}Show in Finder</span><span class="btn">Details</span>`,
    ready: '', stopped: `<span class="btn">${ic('play')}Start Camera</span>`, waiting: '',
  }[state];
  const recBtn = state === 'finishing' ? '<span class="recbtn sm" style="opacity:0.35"></span>'
    : ['nofolder', 'stopped', 'waiting'].includes(state) ? '<span class="recbtn sm dis"></span>' : `<span class="recbtn sm${recOn || state === 'updating' || state === 'paused' ? ' on' : ''}" title="${recOn || state === 'paused' ? 'Stop Recording' : 'Record'}"></span>`;
  const outputCell = mode === 'program'
    ? (role === 'air' ? (programInUse ? '<span class="cg" style="font-size:11.5px">● In Program · on air</span>' : '<span class="c2" style="font-size:11.5px">In Program · no viewer yet</span>')
      : `<span class="btn">${ic('cut')}Cut<span class="c3" style="margin-left:4px">⌃${c.n}</span></span>`)
    : `${ic('camlink', 'sm', inUse ? 'color:var(--green)' : '')}<span>Ultracam · ${c.name}</span><span class="${inUse ? 'cg' : 'c2'}" style="font-size:11px">${inUse ? 'In use' : 'Not in use'}</span>`;
  const cameraBtn = state === 'stopped' ? '' : `<span class="btn" title="Stops capture and output${recOn ? ', and ends the recording (asks first)' : ''}">${ic('stop')}Stop Camera</span>`;

  if (!expanded) {
    const recInline = recOn || state === 'updating' ? `<span class="dot ${state === 'recnosignal' ? 'orange' : 'red'}"></span><span class="tnum">${c.rec.t.replace(/^00:/, '')}</span>${state === 'recnosignal' ? '<span class="co" style="font-size:11px">no signal</span>' : ''}`
      : state === 'paused' ? `<span class="co">❚❚</span><span class="tnum co">${c.rec.t.replace(/^00:/, '')}</span>`
      : state === 'saved' ? '<span class="cg" style="font-size:11.5px">Saved</span>' : state === 'finishing' ? '<span class="c2">Finishing…</span>'
      : state === 'stopped' ? '<span class="c2">Stopped</span>' : state === 'waiting' ? '<span class="co">Waiting for HDMI</span>' : state === 'nofolder' ? '<span class="co">No folder</span>' : state === 'failed' ? '<span class="cr">Stopped · error</span>' : '<span class="c2">Ready</span>';
    return `<div class="strip3 collapsed${tone}${selected ? ' sel-strip' : ''}"><div class="r">
      <span class="chev">${ic('chevr')}</span><b>${c.name}</b>${roleBadge}${recInline}
      ${c.rec.drops ? `<span class="co" style="font-size:11px">${c.rec.drops} dropped</span>` : ''}
      <span style="flex:1"></span>${fxChips(c, { small: true, bypass })}${miniMeter(c)}${recBtn}<span class="btn icon">${ic('ellipsis')}</span>
    </div></div>`;
  }
  return `<div class="strip3${tone}${selected ? ' sel-strip' : ''}">
    <div class="r"><span class="chev">${ic('chevd')}</span><b style="font-size:13.5px" title="${c.input}">${c.name}</b>
      ${statusBadge}${roleBadge}<span style="flex:1"></span>${cameraBtn}<span class="btn icon">${ic('ellipsis')}</span></div>
    <div class="sep3"></div>
    <div class="r">${recBtn}
      <div style="display:flex;flex-direction:column;gap:2px;min-width:0">${recLabel}</div>
      ${recOn || state === 'paused' || state === 'updating' ? `<div style="display:flex;flex-direction:column;gap:2px;margin-left:4px" class="tnum"><span>${c.rec.size} · ${c.rec.rate}</span><span class="${c.rec.drops ? 'co' : 'cg'}" style="font-size:11px">${c.rec.drops ? c.rec.drops + ' dropped' : '0 dropped'}</span></div>` : ''}
      <span style="flex:1"></span>${recActions}</div>
    <div class="r" style="font-size:11.5px">${ic('folder', 'sm c2')}<span>${c.folder}</span><span class="c2 tnum">· ${c.left} left</span>${c.own ? '<span class="badge" style="height:16px">Own folder</span>' : ''}
      <span style="flex:1"></span><span class="c3" style="font-size:11px">Camera original · no LUT or effects</span></div>
    <div class="sep3"></div>
    <div class="r">${outputCell}<span style="flex:1"></span>${state === 'updating' ? `<span class="c2" style="font-size:11px">${ic('refresh')} Updating output…</span>` : ''}${fxChips(c, { bypass })}<span class="lblsw">Processing<span class="switch sm${bypass ? '' : ' on'}"></span></span></div>
    <div class="r" style="gap:8px"><span class="k2" style="width:40px">Audio</span>${meters(c)}</div>
  </div>`;
}

/* sidebar(opts): session panel. With ≤ 2 cameras the strips already show them, so only a compact header remains. */
function sidebar({ mode = 'program', cams = ['c1', 'c2'], programInUse = true, recording = true, inUse = ['c1'] } = {}) {
  const many = cams.length > 2;
  const camRows = many ? cams.map((k) => { const c = CAMS[k]; return `<div class="mini-row"><span class="dot green"></span><div style="flex:1;line-height:1.25"><b style="font-weight:600">${c.name}</b><small>${c.fmt}</small></div></div>`; }).join('') : '';
  const output = mode === 'program' ? `
    <div class="mini-row">${ic('camlink', '', programInUse ? 'color:var(--green)' : '')}<div style="flex:1;line-height:1.25"><b style="font-weight:600">Ultracam · Program</b><small class="${programInUse ? 'cg' : ''}">${programInUse ? 'In use' : 'Not in use'}</small></div></div>
    <div class="mini-row"><span class="c2" style="flex:1">Auto · Natural talking head</span></div>
    <div style="padding:2px 8px 4px">
      <div style="display:flex;justify-content:space-between;font-size:10.5px" class="c2 tnum"><span>Camera 1 · shot 8.2 s</span><span>min 10 s</span></div>
      <div class="shot" style="margin-top:5px"><i style="width:27%"></i><span class="mk" style="left:33.3%"></span><span class="mk" style="left:66.6%"></span><span class="mk" style="left:100%;background:var(--red)"></span></div>
    </div>`
    : cams.map((k) => { const c = CAMS[k]; const u = inUse.includes(k); return `<div class="mini-row">${ic('camlink', '', u ? 'color:var(--green)' : '')}<div style="flex:1;line-height:1.25"><b style="font-weight:600">Ultracam · ${c.name}</b><small class="${u ? 'cg' : ''}">${u ? 'In use' : 'Not in use'}</small></div></div>`; }).join('');
  const drives = [...new Set(cams.map((k) => CAMS[k].drive))].map((d) => {
    const c = cams.map((k) => CAMS[k]).find((x) => x.drive === d);
    return `<div style="padding:3px 8px 2px;display:flex;flex-direction:column;gap:4px">
      <div style="display:flex;align-items:center;gap:6px;font-size:11px">${ic('folder', 'sm c2')}${d}<span class="c2 tnum" style="margin-left:auto">${c.left} left</span></div>
      <div class="gauge"><i style="width:${d === '8TB' ? 93 : 55}%"></i></div></div>`;
  }).join('');
  return `<div class="sidebar glass sb3">
    <div style="position:absolute; top:20px; left:18px;" class="traffic"><span></span><span></span><span></span></div>
    <div style="position:absolute; top:12px; right:10px;" class="tb-btn">${ic('sidebar', '')}</div>
    <div class="side-h">Cameras · ${cams.length}<span class="btn icon" style="height:22px;width:22px" title="Add Camera (stop all cameras first)">${ic('plus')}</span></div>
    ${camRows}
    <div class="side-h">Output</div>${output}
    <div class="side-h">Recording</div>
    <div class="mini-row"><span class="dot ${recording ? 'red' : ''}"></span><div style="flex:1;line-height:1.25"><b style="font-weight:600">${recording ? `${cams.length} recording` : 'Not recording'}</b><small class="tnum">${recording ? '12:31 · ProRes 422' : 'ProRes 422 · Mac clock timecode'}</small></div></div>
    ${drives}
    <div class="side-h">Recent Takes</div>
    <div class="take">${ic('video', 'sm c2')}<div style="flex:1"><span>Today 08:02<span class="c2"> · 38:12</span></span><small>Camera 1_2026-10-21_08-02-11_001.mov</small></div><span class="btn icon" style="height:22px;width:22px" title="Show in Finder">${ic('search')}</span></div>
    <div class="take" style="background:rgba(255,159,10,0.10)">${ic('info', 'sm co')}<div style="flex:1"><span class="co">Interrupted take</span><small>Oct 19 11:15</small></div><span class="btn" style="height:22px;font-size:11px">Recover</span></div>
    <div class="side-h">Automation</div>
    <div class="mini-row" style="padding:2px 8px"><div style="flex:1;line-height:1.25">Start with camera apps<small>Camera 1, Camera 2</small></div></div>
    <div class="mini-row" style="padding:2px 8px"><div style="flex:1;line-height:1.25">Backup recording${newtag}<small>Camera 1, Camera 2 · after 10 s of use</small></div></div>
  </div>`;
}

/* toolbar(opts). Auto lives only here (D: one control). Record control always has a verb. */
function toolbar({ title, subtitle, layout = 'split', mode = 'program', collapsedAll = false, left = 252, rec = 'stopall', recCount = 2, inspector = false, camerasRunning = true } = {}) {
  const lay = [['single', 'Single'], ['split', 'Side by Side'], ['program', 'Program View'], ['grid', 'Four Up']]
    .filter(([k]) => mode === 'program' || k !== 'program')
    .map(([k, label]) => `<div class="tb-btn${k === layout ? ' on' : ' dim'}" title="${label}">${ic(k, '')}</div>`).join('');
  const cuts = mode === 'program' ? `<div class="tb-group glass">
      <div class="tb-btn" style="background:rgba(255,69,58,0.9);color:#fff" title="On air"><span class="kk" style="width:16px;height:16px;font-size:10px;background:rgba(255,255,255,0.25)">1</span>Camera 1</div>
      <div class="tb-btn" title="Cut to Camera 2 (⌃2)"><span class="kk" style="width:16px;height:16px;font-size:10px">2</span>Camera 2</div>
      <div class="tb-sep"></div><div class="tb-btn on" title="Automatic switching (⌃⌥A)">${ic('auto')}Auto</div></div>` : '';
  const recCtl = rec === 'stopall' ? `<div class="tb-prominent red" title="Stop All Recordings (⌥⌘R)">${ic('stop')}Stop All (${recCount})<span class="tnum" style="opacity:0.85;font-weight:500">${'12:31'}</span></div>`
    : rec === 'stop' ? `<div class="tb-prominent red" title="Stop Recording (⌘R)">${ic('stop')}Stop Recording<span class="tnum" style="opacity:0.85;font-weight:500">12:31</span></div>`
    : `<div class="tb-prominent neutral" title="Record All (⌥⌘R)"><span class="dot red" style="box-shadow:none"></span>Record${recCount > 1 ? ' All' : ''}</div>`;
  const camCtl = camerasRunning ? `<div class="tb-group glass"><div class="tb-btn" title="Stop All Cameras">${ic('stop')}Stop Cameras</div></div>`
    : `<div class="tb-group glass"><div class="tb-btn" title="Start Cameras (⌘↩)">${ic('play')}Start Cameras</div></div>`;
  return `<div class="toolbar" style="left:${left}px; right:8px; padding-left:${left > 100 ? 4 : 18}px;">
    ${left < 100 ? `<div class="traffic" style="margin-right:8px"><span></span><span></span><span></span></div><div class="tb-group glass"><div class="tb-btn">${ic('sidebar', '')}</div></div>` : ''}
    <div class="title"><b>${title}</b><small>${subtitle}</small></div>
    <div class="flex"></div>
    ${cuts}
    <div class="tb-group glass">${lay}</div>
    <div class="tb-group glass"><div class="tb-btn${collapsedAll ? ' on' : ''}" title="Collapse All Strips (⌥⌘S)">${ic('chevud', '')}</div></div>
    ${camCtl}
    ${recCtl}
    <div class="tb-group glass"><div class="tb-btn${inspector ? ' on' : ''}" title="Inspector (⌥⌘I)">${ic('inspector', '')}</div></div>
  </div>`;
}

/* statusbar: fixed order — Output · Program · Recording · Audio · spacer · Resources. No app names. */
function statusbar({ mode = 'program', programInUse = true, cams = ['c1', 'c2'], recording = true, inUse = ['c1'], warn = null } = {}) {
  const out = mode === 'program' ? `Ultracam · Program · ${programInUse ? 'in use' : 'not in use'}`
    : inUse.length ? `${inUse.map((k) => 'Ultracam · ' + CAMS[k].name).join(', ')} · in use` : 'Virtual cameras not in use';
  const drives = [...new Set(cams.map((k) => CAMS[k].drive))].map((d) => `${d} ${cams.map((k) => CAMS[k]).find((x) => x.drive === d).left}`).join(' · ');
  return `<div class="sbar tnum">
    <div class="seg2 hover ${(mode === 'program' ? programInUse : inUse.length) ? 'cg' : 'c2'}">${ic('camlink')}${out}</div>
    ${mode === 'program' ? `<div class="div"></div><div class="seg2">${ic('program')}Camera 1 on air · Auto</div>` : ''}
    <div class="div"></div>
    <div class="seg2">${recording ? `<span class="dot red" style="box-shadow:none"></span><span style="color:var(--label)">REC ${cams.length > 1 ? cams.length + ' · ' : ''}12:31</span> · ` : ''}${drives} left</div>
    <div class="div"></div>
    <div class="seg2">${ic('wave')}${cams.length > 1 ? 'Audio: 2 of 2' : 'Audio OK'}</div>
    ${warn ? `<div class="div"></div><div class="seg2 co">${ic('info')}${warn}</div>` : ''}
    <div class="sp"></div>
    <div class="seg2">CPU ${cams.length > 1 ? '48.6' : '31.4'}% · GPU (video) ${cams.length > 1 ? '29.8' : '18.2'}% · Memory ${cams.length > 1 ? '1.71' : '1.08'} GB</div>
  </div>`;
}

/* inspector(c): on-demand deep settings for the selected camera (D5). Closed by default. */
function inspector(c, { mode = 'program' } = {}) {
  return `<div class="insp3 glass">
    <div style="position:absolute;top:16px;left:14px;right:14px;display:flex;align-items:center;gap:8px"><b style="font-size:13.5px">${c.name}</b><span class="c2" style="font-size:11px">${c.input}</span></div>
    <div class="form-h" style="padding-top:2px">Source</div>
    <div class="form">
      <div class="row"><span class="lbl">Input</span><span class="popup plain" style="opacity:0.55" title="Stop the camera to change its input">${c.input.split(' · ')[1]}<span class="chev">${ic('chevud')}</span></span></div>
      <div class="row"><span class="lbl">Signal</span><span class="val mono">${c.fmt} · 4:2:2</span></div>
      <div class="row"><span class="lbl">Timecode</span><span class="val mono">14:22:31:12</span></div>
    </div>
    <div class="form-h">Processing <span class="lblsw" style="font-weight:500">Processing<span class="switch sm on"></span></span></div>
    <div class="form">
      ${FX_NAMES.map((n, i) => `<div class="row"><div class="check${c.fx[i] ? ' on' : ''}${i === 0 && !c.lut ? ' off-dim' : ''}"></div><span class="lbl">${i + 1} · ${['LUT', 'Downscale to 1080p', 'Color 4:2:0 8-bit', 'Limit to 29.97 fps'][i]}<small>${i === 0 ? (c.lut ? 'Live-safe' : 'Load a .cube to enable') : 'Changes the camera output format'}</small></span></div>`).join('')}
    </div>
    <div class="note cg">✓ Effects active · ${c.out} to ${mode === 'program' ? 'Program' : 'its camera'}</div>
    <div class="form-h">LUT</div>
    <div class="form">
      <div class="row">${ic('cube', 'c2')}<span class="lbl" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${c.lut ? c.lut + '.cube' : 'No LUT loaded'}</span><span class="btn">${c.lut ? 'Change…' : 'Load LUT…'}</span></div>
      <div class="row"><span class="lbl">LUT input</span><span class="popup plain">S-Gamut3.Cine / S-Log3<span class="chev">${ic('chevud')}</span></span></div>
    </div>
    <div class="form-h">Recording</div>
    <div class="form"><div class="row">${ic('folder', 'c2')}<span class="lbl" style="font-size:12px">${c.folder}<small>${c.own ? 'Own folder' : 'Default folder'} · applies to the next take</small></span>${c.own ? '<span class="btn borderless">Use Default</span>' : '<span class="btn">Choose…</span>'}</div></div>
    <div class="form-h">Automation</div>
    <div class="form">
      <div class="row"><span class="lbl">Start with camera apps</span><div class="switch sm on"></div></div>
      <div class="row"><span class="lbl">Backup recording${newtag}<small>Starts after 10 s of camera use · stops only takes it started</small></span><div class="switch sm on"></div></div>
    </div>
  </div>`;
}

function mount(id, html) { document.getElementById(id).innerHTML = html; }
