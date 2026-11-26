'use strict';
// Runs on the remote runner only. Never reads the connecting computer's browser.
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const {spawn, execFileSync} = require('node:child_process');
const {pipeline} = require('node:stream/promises');
const {Readable} = require('node:stream');
const MAGIC = Buffer.from('WFCB0001');
const platform = process.platform === 'win32' ? 'windows' : 'macos';
const root = process.env.BROWSER_DATA_ROOT || (platform === 'windows'
  ? path.join(process.env.LOCALAPPDATA, 'WorkflowChrome')
  : path.join(os.homedir(), 'Library/Application Support/WorkflowChrome'));
const profile = path.join(root, 'User Data');
const temp = process.env.RUNNER_TEMP || os.tmpdir();
const readyFile = path.join(temp, 'workflow-browser-ready');
const stopFile = path.join(temp, 'workflow-browser-stop');
const lockFile = path.join(temp, 'workflow-browser-lock');
const repo = process.env.BROWSER_BACKUP_REPOSITORY;
const token = process.env.GH_TOKEN;
const tag = process.env.BROWSER_BACKUP_TAG || 'browser-data';
const pause = ms => new Promise(r => setTimeout(r, ms));
function key() {
  const value = Buffer.from(process.env.BROWSER_BACKUP_KEY || '', 'base64');
  if (value.length !== 32) throw Error('BROWSER_BACKUP_KEY must be 32 random bytes, base64 encoded');
  return value;
}
async function encryptFile(input, output, secret) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', secret, iv);
  cipher.setAAD(MAGIC);
  await fsp.writeFile(output, Buffer.concat([MAGIC, iv]), {mode:0o600});
  await pipeline(fs.createReadStream(input), cipher, fs.createWriteStream(output, {flags:'a', mode:0o600}));
  await fsp.appendFile(output, cipher.getAuthTag());
}
async function decryptFile(input, output, secret) {
  const stat = await fsp.stat(input);
  if (stat.size < 36) throw Error('Truncated browser backup');
  const file = await fsp.open(input, 'r');
  const header = Buffer.alloc(20), auth = Buffer.alloc(16);
  try { await file.read(header, 0, 20, 0); await file.read(auth, 0, 16, stat.size - 16); }
  finally { await file.close(); }
  if (!header.subarray(0, 8).equals(MAGIC)) throw Error('Unknown browser backup format');
  const decipher = crypto.createDecipheriv('aes-256-gcm', secret, header.subarray(8));
  decipher.setAAD(MAGIC); decipher.setAuthTag(auth);
  try { await pipeline(fs.createReadStream(input, {start:20, end:stat.size-17}), decipher, fs.createWriteStream(output, {mode:0o600})); }
  catch (e) { await fsp.rm(output, {force:true}); throw Error('Backup authentication failed; restore stopped'); }
}
async function api(route, options={}) {
  if (!repo || !token) throw Error('Missing repository or GitHub token');
  const response = await fetch('https://api.github.com/repos/'+repo+route, {
    ...options, headers:{Authorization:'Bearer '+token, Accept:'application/vnd.github+json',
      'User-Agent':'workflow-browser-backup', ...options.headers}, signal:AbortSignal.timeout(60000)
  });
  if (response.status === 404 && options.missingOK) return null;
  if (!response.ok) throw Error('GitHub backup API returned '+response.status);
  return response.status === 204 ? null : response.json();
}
async function release(create=false) {
  let item = await api('/releases/tags/'+tag, {missingOK:true});
  if (!item && create) {
    try { item = await api('/releases', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({
      tag_name:tag, name:'Encrypted remote Chrome data', prerelease:true,
      body:'AES-256-GCM encrypted Chrome profiles. Windows and macOS are independent. The decryption key is stored in Actions Secrets. No plaintext browser data is published.'
    })}); } catch(e) { item = await api('/releases/tags/'+tag); }
  }
  return item;
}
async function assets(item) { return api('/releases/'+item.id+'/assets?per_page=100'); }
async function download(asset, output) {
  let response=await fetch('https://api.github.com/repos/'+repo+'/releases/assets/'+asset.id,{
    headers:{Authorization:'Bearer '+token,Accept:'application/octet-stream','User-Agent':'workflow-browser-backup'},
    redirect:'manual',signal:AbortSignal.timeout(60000)});
  if([301,302,303,307,308].includes(response.status)){
    const location=new URL(response.headers.get('location'));
    if(location.protocol!=='https:')throw Error('Unsafe backup download redirect');
    response=await fetch(location,{signal:AbortSignal.timeout(300000)});
  }
  if(!response.ok)throw Error('Private browser archive download failed: '+response.status);
  await pipeline(Readable.fromWeb(response.body),fs.createWriteStream(output,{mode:0o600}));
}
async function upload(item, file, prefix) {
  const size=(await fsp.stat(file)).size;
  if(size>=2*1024**3)throw Error('Encrypted profile exceeds GitHub release asset limit; prior backups preserved');
  const name=prefix+Date.now()+'-'+process.env.GITHUB_RUN_ID+'.enc';
  const url=item.upload_url.split('{')[0]+'?name='+encodeURIComponent(name);
  const response=await fetch(url,{method:'POST',headers:{Authorization:'Bearer '+token,
    'User-Agent':'workflow-browser-backup','Content-Type':'application/octet-stream','Content-Length':String(size)},
    body:fs.createReadStream(file),duplex:'half',signal:AbortSignal.timeout(300000)});
  if(!response.ok)throw Error('Encrypted backup upload failed: '+response.status);
  const saved=await response.json();
  if(saved.state!=='uploaded'||saved.size!==size)throw Error('Uploaded browser archive verification failed');
  const all=(await assets(item)).filter(a=>a.name.startsWith(prefix)&&a.name.endsWith('.enc')).sort((a,b)=>b.id-a.id);
  for(const old of all.slice(2))await api('/releases/assets/'+old.id,{method:'DELETE'});
  return saved;
}
const bookmarkFile=path.join(profile,'Default','Bookmarks');
const bookmarkBaseline=path.join(temp,'workflow-bookmark-hash');
async function bookmarkHash(){try{return crypto.createHash('sha256').update(await fsp.readFile(bookmarkFile)).digest('hex');}catch(e){if(e.code==='ENOENT')return '';throw e;}}
async function bookmarksRestore(item){
  if(item){
    const latest=(await assets(item)).filter(a=>a.name.startsWith('bookmarks-')&&a.name.endsWith('.enc')).sort((a,b)=>b.id-a.id)[0];
    if(latest){
      const staging=await fsp.mkdtemp(path.join(temp,'bookmarks-restore-'));
      try{
        const enc=path.join(staging,'bookmarks.enc'),plain=path.join(staging,'Bookmarks');
        await download(latest,enc);await decryptFile(enc,plain,key());
        const value=JSON.parse(await fsp.readFile(plain,'utf8'));if(!value.roots)throw Error('Invalid bookmarks backup');
        await fsp.mkdir(path.dirname(bookmarkFile),{recursive:true,mode:0o700});
        await fsp.copyFile(plain,bookmarkFile);
        console.log('Loaded shared bookmarks from the private backup repository');
      }finally{await fsp.rm(staging,{recursive:true,force:true});}
    }
  }
  await fsp.writeFile(bookmarkBaseline,await bookmarkHash(),{mode:0o600});
}
async function bookmarksSave(item,staging){
  const hash=await bookmarkHash();
  const before=fs.existsSync(bookmarkBaseline)?await fsp.readFile(bookmarkBaseline,'utf8'):'';
  if(!hash||hash===before)return;
  const plain=path.join(staging,'Bookmarks'),enc=path.join(staging,'bookmarks.enc');
  await fsp.copyFile(bookmarkFile,plain);JSON.parse(await fsp.readFile(plain,'utf8'));
  await encryptFile(plain,enc,key());await upload(item,enc,'bookmarks-');
  await fsp.writeFile(bookmarkBaseline,hash,{mode:0o600});
  console.log('Updated shared encrypted bookmarks');
}
async function fileHash(file){const hash=crypto.createHash('sha256');for await(const chunk of fs.createReadStream(file))hash.update(chunk);return hash.digest('hex');}
function safeManagedRoot(){
  const expected=platform==='windows'?path.join(process.env.LOCALAPPDATA,'WorkflowChrome'):path.join(os.homedir(),'Library/Application Support/WorkflowChrome');
  const actual=path.resolve(root);
  if(actual!==path.resolve(expected)&&!actual.startsWith(path.resolve(temp)+path.sep))throw Error('Unsafe managed Chrome directory');
}
async function localSeedRestore(item){
  if(!item)return false;
  const pointer=process.env.BROWSER_LOCAL_SEED_MANIFEST_ID;
  const priorMarker=path.join(root,'local-seed-applied.json');
  if(pointer&&fs.existsSync(priorMarker)&&String(JSON.parse(await fsp.readFile(priorMarker,'utf8')).manifest_id)===pointer){console.log('Keeping the newest remote data; the baseline is already applied');return false;}
  const asset=pointer&&/^\d+$/.test(pointer)?await api('/releases/assets/'+pointer):
    (await assets(item)).filter(a=>a.name.startsWith('local-seed-manifest-')&&a.name.endsWith('.enc')).sort((a,b)=>b.id-a.id)[0];
  if(!asset)return false;
  if(!asset.name.startsWith('local-seed-manifest-'))throw Error('Invalid local seed pointer');
  const staging=await fsp.mkdtemp(path.join(temp,'local-chrome-restore-'));
  let previous;
  try{
    const manifestCipher=path.join(staging,'manifest.enc'),manifestFile=path.join(staging,'manifest.json');
    await download(asset,manifestCipher);await decryptFile(manifestCipher,manifestFile,key());
    const manifest=JSON.parse(await fsp.readFile(manifestFile,'utf8'));
    if(manifest.format!==1||manifest.kind!=='local-chrome-seed'||!/^\d{13}-[a-f0-9]{8}$/.test(manifest.id)||!Array.isArray(manifest.parts)||manifest.parts.length<1||manifest.parts.length>100)throw Error('Invalid local Chrome seed manifest');
    const marker=path.join(root,'local-seed-applied.json');
    if(fs.existsSync(marker)&&JSON.parse(await fsp.readFile(marker,'utf8')).id===manifest.id){console.log('Keeping the latest remote profile; local seed was already imported');return false;}
    const encrypted=path.join(staging,'profile.enc');await fsp.writeFile(encrypted,Buffer.alloc(0),{mode:0o600});
    for(const part of manifest.parts){
      if(!Number.isSafeInteger(part.id)||!part.name.startsWith('local-seed-part-'+manifest.id+'-')||!/^[a-f0-9]{64}$/.test(part.sha256))throw Error('Invalid Chrome seed part');
      const meta=await api('/releases/assets/'+part.id);
      if(meta.name!==part.name||meta.size!==part.bytes)throw Error('Chrome seed part metadata mismatch');
      const file=path.join(staging,'part.enc');await download(meta,file);
      if((await fsp.stat(file)).size!==part.bytes||await fileHash(file)!==part.sha256)throw Error('Chrome seed part verification failed');
      await pipeline(fs.createReadStream(file),fs.createWriteStream(encrypted,{flags:'a'}));await fsp.rm(file);
    }
    if((await fsp.stat(encrypted)).size!==manifest.bytes||await fileHash(encrypted)!==manifest.sha256)throw Error('Chrome seed verification failed');
    const archive=path.join(staging,'profile.tar.gz');await decryptFile(encrypted,archive,key());
    const entries=execFileSync('tar',['-tzf',archive],{encoding:'utf8',maxBuffer:32*1024*1024,windowsHide:true}).split(/\r?\n/).filter(Boolean);
    if(entries.some(n=>!n.startsWith('User Data/')||n.split(/[\\/]/).includes('..')))throw Error('Unsafe local Chrome seed archive');
    const extracted=path.join(staging,'extracted');await fsp.mkdir(extracted);
    execFileSync('tar',['-xzf',archive,'-C',extracted],{windowsHide:true});
    if(!fs.existsSync(path.join(extracted,'User Data','Local State')))throw Error('Local Chrome profile is incomplete');
    safeManagedRoot();
    if(fs.existsSync(root)){previous=root+'.before-seed-'+crypto.randomBytes(6).toString('hex');await fsp.rename(root,previous);}
    try{
      await fsp.mkdir(root,{recursive:true,mode:0o700});
      await fsp.cp(path.join(extracted,'User Data'),profile,{recursive:true,preserveTimestamps:true});
      await fsp.writeFile(marker,JSON.stringify({id:manifest.id,manifest_id:asset.id,imported:new Date().toISOString()}),{mode:0o600});
      await fsp.writeFile(path.join(root,'backup-manifest.json'),JSON.stringify({format:1,platform,local_seed:manifest.id}),{mode:0o600});
    }catch(e){await fsp.rm(root,{recursive:true,force:true});if(previous){await fsp.rename(previous,root);previous=undefined;}throw e;}
    console.log('Imported the encrypted local Chrome baseline; future sessions will use their newest platform backup');
    return true;
  }finally{
    if(previous){if(!previous.startsWith(root+'.before-seed-'))throw Error('Unsafe previous-profile cleanup');await fsp.rm(previous,{recursive:true,force:true});}
    await fsp.rm(staging,{recursive:true,force:true});
  }
}
async function restore() {
  key();
  if(!(await api('')).private)throw Error('Browser backup repository must be private');
  await fsp.rm(readyFile, {force:true});
  await fsp.rm(stopFile, {force:true});
  const item = await release();
  const list = item ? (await assets(item)).filter(a => a.name.startsWith('chrome-'+platform+'-') && a.name.endsWith('.enc')).sort((a,b)=>b.id-a.id) : [];
  if (list.length) {
    const staging = await fsp.mkdtemp(path.join(temp, 'chrome-restore-'));
    try {
      const encrypted = path.join(staging, 'backup.enc'), archive = path.join(staging, 'profile.tar.gz');
      await download(list[0],encrypted);
      await decryptFile(encrypted, archive, key());
      const entries = execFileSync('tar', ['-tzf', archive], {encoding:'utf8', maxBuffer:32*1024*1024, windowsHide:true}).split(/\r?\n/).filter(Boolean);
      if (entries.some(name => name.startsWith('/') || /^[A-Za-z]:/.test(name) || name.split(/[\\/]/).includes('..'))) throw Error('Unsafe archive path');
      const extracted = path.join(staging,'extracted'); await fsp.mkdir(extracted);
      execFileSync('tar', ['-xzf', archive, '-C', extracted], {windowsHide:true});
      const manifest = JSON.parse(await fsp.readFile(path.join(extracted,'backup-manifest.json'),'utf8'));
      if (manifest.platform !== platform || manifest.format !== 1) throw Error('Wrong platform or unsupported backup');
      if (fs.existsSync(root) && (await fsp.readdir(root)).length) throw Error('Refusing to overwrite an existing browser profile');
      await fsp.mkdir(root, {recursive:true, mode:0o700});
      // Runner temp and the Windows user profile can be on different volumes.
      for (const name of await fsp.readdir(extracted)) await fsp.cp(path.join(extracted,name),path.join(root,name),{recursive:true,preserveTimestamps:true});
      console.log('Restored authenticated Chrome profile backup for '+platform);
    } finally { await fsp.rm(staging, {recursive:true, force:true}); }
  } else {
    await fsp.mkdir(root, {recursive:true, mode:0o700});
    console.log('No prior '+platform+' browser backup; preparing a new profile');
  }
  const importedLocal=await localSeedRestore(item);
  // Clear only transient locks, never browser databases or caches.
  for (const name of ['SingletonLock','SingletonCookie','SingletonSocket','DevToolsActivePort']) await fsp.rm(path.join(profile,name),{force:true});
  if(importedLocal)await fsp.writeFile(bookmarkBaseline,'',{mode:0o600});else await bookmarksRestore(item);
  await fsp.writeFile(readyFile, 'ready', {mode:0o600});
}
async function cdp(method, params={}) {
  const version = await (await fetch('http://127.0.0.1:9222/json/version', {signal:AbortSignal.timeout(4000)})).json();
  const url = new URL(version.webSocketDebuggerUrl);
  if (!['127.0.0.1','localhost'].includes(url.hostname)) throw Error('Unexpected browser endpoint');
  return new Promise((resolve,reject)=>{
    const socket = new WebSocket(url);
    const timeout = setTimeout(()=>{ socket.close(); reject(Error('Browser operation timed out')); },15000);
    socket.addEventListener('open',()=>socket.send(JSON.stringify({id:1,method,params})));
    socket.addEventListener('error',()=>{clearTimeout(timeout);reject(Error('Browser endpoint unavailable'));});
    socket.addEventListener('message',event=>{
      const message = JSON.parse(event.data); if (message.id!==1) return;
      clearTimeout(timeout);socket.close();
      message.error ? reject(Error('Browser operation failed: '+message.error.message)) : resolve(message.result);
    });
    // Browser.close may close the socket before returning a response.
    socket.addEventListener('close',()=>{if(method==='Browser.close'){clearTimeout(timeout);resolve({});}});
  });
}
async function cookiesExport() {
  const {cookies} = await cdp('Storage.getCookies');
  await fsp.writeFile(path.join(root, 'portable-cookies.json'), JSON.stringify(cookies), {mode:0o600});
  console.log('Browser session checkpoint captured (values kept private)');
}
async function tabsExport(){
  const privateContexts=(await cdp('Target.getBrowserContexts')).browserContextIds;
  const targets=(await cdp('Target.getTargets')).targetInfos.filter(t=>t.type==='page'&&!privateContexts.includes(t.browserContextId)&&!t.url.startsWith('devtools://'));
  const windows=new Map();
  for(const target of targets){
    try{
      const window=await cdp('Browser.getWindowForTarget',{targetId:target.targetId});
      if(!windows.has(window.windowId))windows.set(window.windowId,{bounds:window.bounds,urls:[]});
      windows.get(window.windowId).urls.push(target.url||'about:blank');
    }catch{}
  }
  await fsp.writeFile(path.join(root,'portable-tabs.json'),JSON.stringify([...windows.values()]),{mode:0o600});
}
async function tabsImport(){
  const file=path.join(root,'portable-tabs.json');if(!fs.existsSync(file))return;
  const windows=JSON.parse(await fsp.readFile(file,'utf8'));
  for(const window of windows){
    let windowId;
    for(const original of window.urls){
      const url=/^(https?:|chrome:|about:)/.test(original)?original:'about:blank';
      const created=await cdp('Target.createTarget',{url,newWindow:windowId===undefined});
      if(windowId===undefined)windowId=(await cdp('Browser.getWindowForTarget',{targetId:created.targetId})).windowId;
    }
    if(windowId!==undefined&&window.bounds){
      const bounds=window.bounds;
      try{
        if(bounds.windowState==='normal')await cdp('Browser.setWindowBounds',{windowId,bounds:{left:bounds.left,top:bounds.top,width:bounds.width,height:bounds.height,windowState:'normal'}});
        else await cdp('Browser.setWindowBounds',{windowId,bounds:{windowState:bounds.windowState}});
      }catch{}
    }
  }
  console.log('Restored saved Chrome windows and tabs after restoring cookies');
}
async function cookiesImport() {
  const file = path.join(root,'portable-cookies.json');
  if (!fs.existsSync(file)) return;
  const cookies = JSON.parse(await fsp.readFile(file,'utf8')).map(cookie=>{
    const result={};
    for (const field of ['name','value','domain','path','secure','httpOnly','sameSite','priority','sameParty','sourceScheme','sourcePort','partitionKey']) if(cookie[field]!==undefined) result[field]=cookie[field];
    if(!cookie.session && cookie.expires>0)result.expires=cookie.expires;
    return result;
  });
  await cdp('Storage.setCookies', {cookies});
  console.log('Restored portable browser cookies');
}
function chromePath() {
  const candidates = platform === 'windows' ? [
    path.join(process.env.PROGRAMFILES || 'C:/Program Files','Google/Chrome/Application/chrome.exe'),
    path.join(process.env['PROGRAMFILES(X86)'] || 'C:/Program Files (x86)','Google/Chrome/Application/chrome.exe')
  ] : ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'];
  const found = candidates.find(fs.existsSync); if(!found)throw Error('Google Chrome is not installed'); return found;
}
async function launch(importCookies=true) {
  if (!fs.existsSync(readyFile)) throw Error('Browser restore has not completed');
  const args = ['--user-data-dir='+profile,'--disk-cache-dir='+path.join(profile,'Disk Cache'),
    '--remote-debugging-address=127.0.0.1','--remote-debugging-port=9222',
    '--no-first-run','--no-default-browser-check','--no-startup-window'];
  const child = spawn(chromePath(), args, {detached:true, stdio:'ignore',windowsHide:true}); child.unref();
  let up=false;
  for(let i=0;i<60;i++){try{await cdp('Browser.getVersion');up=true;break;}catch{await pause(1000);}}
  if(!up)throw Error('Chrome background startup did not become ready');
  if(importCookies)await cookiesImport();
  // A non-account test cookie verifies transport across newly provisioned machines.
  const probeFile=path.join(root,'backup-probe.json');
  if(importCookies && fs.existsSync(probeFile)){
    const probe=JSON.parse(await fsp.readFile(probeFile,'utf8'));
    const result=await cdp('Storage.getCookies');
    if(!result.cookies.some(c=>c.name==='workflow_backup_probe'&&c.domain==='workflow-backup.invalid'&&c.value===probe.value))throw Error('Restored browser cookie verification failed');
    console.log('Cross-machine browser cookie restore verified');
  }else if(!fs.existsSync(probeFile)){
    const value=crypto.randomBytes(18).toString('hex');
    await cdp('Storage.setCookies',{cookies:[{name:'workflow_backup_probe',value,domain:'workflow-backup.invalid',path:'/',secure:true,httpOnly:true,expires:Date.now()/1000+365*86400}]});
    await fsp.writeFile(probeFile,JSON.stringify({value}),{mode:0o600});
  }
  const tabFile=path.join(root,'portable-tabs.json');
  const savedTabs=fs.existsSync(tabFile)?JSON.parse(await fsp.readFile(tabFile,'utf8')):null;
  let nativeRestored=false;
  if(importCookies&&(!savedTabs||savedTabs.some(w=>w.urls.length))&&fs.existsSync(path.join(profile,'Default','Sessions'))){
    // Let Chrome read its own session files only after cookie restoration.
    const restore=spawn(chromePath(),['--user-data-dir='+profile,'--disk-cache-dir='+path.join(profile,'Disk Cache'),'--restore-last-session','--no-first-run','--no-default-browser-check'],{detached:true,stdio:'ignore',windowsHide:true});restore.unref();
    console.log('Requested restoration of the imported Chrome session files');
    for(let i=0;i<15;i++){if((await cdp('Target.getTargets')).targetInfos.some(t=>t.type==='page')){nativeRestored=true;break;}await pause(1000);}
  }
  if(importCookies&&!nativeRestored)await tabsImport();
  console.log('Chrome is ready; remote debugging listens on loopback only');
}
async function tar(output,final=false,useSnapshot=true) {
  try {await new Promise((resolve,reject)=>{
    const args=['--exclude=SingletonLock','--exclude=SingletonSocket','--exclude=SingletonCookie',
      '--exclude=DevToolsActivePort','--exclude=LOCK','--exclude=lockfile','-czf',output,'-C',root,'.'];
    const snapshot=platform==='windows'&&!final&&useSnapshot;
    if(platform==='windows'&&!final&&!useSnapshot){
      // The exported cookie store preserves values while Chrome locks this raw DB.
      for(const p of ['Default/Network/Cookies','Default/Cookies'])for(const suffix of ['','-journal','-wal','-shm'])args.unshift('--exclude=./User Data/'+p+suffix);
    }
    const child = spawn(snapshot?'pwsh':'tar',snapshot?[
      '-NoProfile','-NonInteractive','-File',path.join(__dirname,'archive-chrome-windows.ps1'),'-Root',root,'-Archive',output
    ]:args,{windowsHide:true,stdio:['ignore','ignore','pipe'],timeout:snapshot?30000:180000});
    let error='';child.stderr.on('data',data=>{error+=data.toString();});
    child.on('error',reject);child.on('close',code=>{
      // A live database can change during a periodic snapshot; a final closed snapshot follows.
      if(code===0 || (code===1 && /file changed as we read it|file shrank/i.test(error)))resolve();
      else reject(Error('Profile archive failed; prior backup preserved (archive exit '+code+')'));
    });
  });}catch(e){
    if(platform!=='windows'||final||!useSnapshot)throw e;
    console.log('Windows snapshot unavailable; using the portable cookie checkpoint with a live profile archive');
    await tar(output,final,false);
  }
}
async function backup(final=false) {
  if(!fs.existsSync(readyFile))throw Error('Restore incomplete; refusing to replace the saved browser data');
  let lock;
  try { lock=await fsp.open(lockFile,'wx'); }
  catch(e){if(e.code==='EEXIST')return;throw e;}
  await lock.writeFile(JSON.stringify({pid:process.pid,started:Date.now()}));
  let staging;
  try {
    if(!fs.existsSync(path.join(profile,'Local State')))throw Error('Chrome profile has not initialized');
    try { await cookiesExport();await tabsExport(); }
    catch(e){if(!final)throw e;console.log('Browser is closed; retaining its most recent portable cookie checkpoint');}
    if(final){try{await cdp('Browser.close');}catch{}await pause(4000);}
    await fsp.writeFile(path.join(root,'backup-manifest.json'),JSON.stringify({format:1,platform,run:process.env.GITHUB_RUN_ID,created:new Date().toISOString(),final}),{mode:0o600});
    staging = await fsp.mkdtemp(path.join(temp,'chrome-backup-'));
    const archive=path.join(staging,'profile.tar.gz'),encrypted=path.join(staging,'profile.enc');
    await tar(archive,final); await encryptFile(archive,encrypted,key());
    const item=await release(true);
    const saved=await upload(item,encrypted,'chrome-'+platform+'-');
    const size=saved.size;
    await bookmarksSave(item,staging);
    console.log('Encrypted '+platform+' Chrome backup uploaded ('+size+' bytes)');
    await fsp.writeFile(path.join(temp,'browser-backup-status.json'),JSON.stringify({platform,asset:saved.name,bytes:size,final,at:new Date().toISOString()}));
  } finally { if(staging)await fsp.rm(staging,{recursive:true,force:true});await lock.close();await fsp.rm(lockFile,{force:true}); }
}
async function watch() {
  while(!fs.existsSync(stopFile)){
    try{try{await cdp('Browser.getVersion');}catch{await launch(false);}await backup();}catch(e){console.error('Browser checkpoint: '+e.message);}
    for(let i=0;i<150&&!fs.existsSync(stopFile);i++)await pause(1000);
  }
}
async function finish() {
  await fsp.writeFile(stopFile,'stop');
  for(let i=0;i<360&&fs.existsSync(lockFile);i++){
    try{
      const owner=JSON.parse(await fsp.readFile(lockFile,'utf8'));
      if(Number.isInteger(owner.pid)){try{process.kill(owner.pid,0);}catch(e){if(e.code==='ESRCH'){await fsp.rm(lockFile,{force:true});break;}}}
    }catch{}
    await pause(1000);
  }
  if(fs.existsSync(lockFile))throw Error('Browser checkpoint still busy; final backup could not start');
  await backup(true);
}
async function session(){
  const minutes=Number(process.env.SESSION_MINUTES);
  if(!Number.isInteger(minutes)||minutes<10||minutes>300)throw Error('Invalid browser session duration');
  const deadline=Date.now()+minutes*60000;
  let failures=0;
  while(Date.now()<deadline){
    await pause(Math.min(150000,Math.max(0,deadline-Date.now())));
    if(Date.now()>=deadline)break;
    try{
      try{await cdp('Browser.getVersion');}catch{await launch(false);}
      await backup();failures=0;
    }catch(e){
      console.error('Browser checkpoint: '+e.message);
      if(++failures>=5)throw Error('Browser backup failed repeatedly; ending session with a final backup');
    }
  }
}
async function main(){
  const command=process.argv[2];
  if(command==='restore')await restore();else if(command==='launch')await launch();
  else if(command==='backup')await backup();else if(command==='watch')await watch();
  else if(command==='finish')await finish();else if(command==='session')await session();else throw Error('Unknown browser-data command');
}
module.exports={encryptFile,decryptFile,bookmarksSave,bookmarksRestore,release,api,root,profile,cdp,tabsExport,tabsImport,upload,download,localSeedRestore};
if(require.main===module)main().catch(e=>{console.error(e.message);process.exitCode=1;});
