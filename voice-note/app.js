const DB_NAME='golos-audio-db',DB_VERSION=1,STORE='items';
let db,recorder,stream,chunks=[],startedAt=0,elapsedBeforePause=0,timerHandle=null,currentItem=null,activeFilter='all',toastHandle;
const $=id=>document.getElementById(id);
const wave=$('wave');
for(let i=0;i<61;i++){const bar=document.createElement('i');bar.style.setProperty('--h',(8+Math.round(Math.abs(Math.sin(i*12.9898)*Math.cos(i*3.21))*36))+'px');bar.style.setProperty('--d',(i%9)*-0.07+'s');wave.appendChild(bar)}
function openDB(){return new Promise((resolve,reject)=>{const req=indexedDB.open(DB_NAME,DB_VERSION);req.onupgradeneeded=()=>{const store=req.result.createObjectStore(STORE,{keyPath:'id'});store.createIndex('createdAt','createdAt')};req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error)})}
function tx(mode,fn){return new Promise((resolve,reject)=>{const t=db.transaction(STORE,mode),s=t.objectStore(STORE);let req=fn(s);t.oncomplete=()=>resolve(req?.result);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error)})}
const allItems=()=>tx('readonly',s=>s.getAll());
const putItem=item=>tx('readwrite',s=>s.put(item));
const removeItem=id=>tx('readwrite',s=>s.delete(id));
function makeId(){return crypto.randomUUID?crypto.randomUUID():Date.now()+'-'+Math.random().toString(16).slice(2)}
function fmtTime(ms){const sec=Math.max(0,Math.floor(ms/1000));return String(Math.floor(sec/60)).padStart(2,'0')+':'+String(sec%60).padStart(2,'0')}
function fmtDate(ts){return new Intl.DateTimeFormat('ru-RU',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}).format(new Date(ts))}
function showToast(msg){const t=$('toast');t.textContent=msg;t.classList.add('show');clearTimeout(toastHandle);toastHandle=setTimeout(()=>t.classList.remove('show'),2300)}
function setTab(tab){document.querySelectorAll('.tab').forEach(b=>b.classList.toggle('active',b.dataset.tab===tab));$('recordView').hidden=tab!=='record';$('libraryView').hidden=tab!=='library';if(tab==='library')renderLibrary()}
document.querySelectorAll('.tab').forEach(b=>b.addEventListener('click',()=>setTab(b.dataset.tab)));
$('allRecordingsBtn').onclick=()=>setTab('library');
$('recordBtn').onclick=()=>recorder&&recorder.state==='recording'?pauseRecording():startRecording();
$('pauseBtn').onclick=()=>recorder?.state==='recording'?pauseRecording():resumeRecording();
$('finishBtn').onclick=finishRecording;
async function startRecording(){
 if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder){showToast('Запись не поддерживается этим браузером');return}
 try{
  stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
  chunks=[];const candidates=['audio/mp4;codecs=mp4a.40.2','audio/webm;codecs=opus','audio/webm','audio/mp4'];const mime=typeof MediaRecorder.isTypeSupported==='function'?candidates.find(t=>MediaRecorder.isTypeSupported(t)):'';
  recorder=new MediaRecorder(stream,mime?{mimeType:mime}:undefined);
  recorder.ondataavailable=e=>{if(e.data&&e.data.size)chunks.push(e.data)};
  recorder.onstop=saveRecording;
  recorder.start(1000);startedAt=Date.now();elapsedBeforePause=0;
  $('recordState').textContent='ИДЁТ ЗАПИСЬ';$('recordHint').textContent='Идёт запись. Не закрывайте приложение.';$('micStatus').textContent='МИКРОФОН АКТИВЕН';
  $('recordBtn').setAttribute('aria-label','Поставить запись на паузу');$('recordCard')?.classList.add('recording');document.querySelector('.record-card').classList.add('recording');
  $('pauseBtn').disabled=false;$('finishBtn').disabled=false;$('pauseBtn').textContent='Ⅱ Пауза';$('recordBtn').classList.add('is-recording');
  timerHandle=setInterval(updateTimer,250);updateTimer();
 }catch(err){showToast(err.name==='NotAllowedError'?'Разрешите доступ к микрофону':'Не удалось включить микрофон');console.error(err)}
}
function updateTimer(){const ms=elapsedBeforePause+(recorder?.state==='recording'?Date.now()-startedAt:0);$('timer').innerHTML=fmtTime(ms)+'<span> / запись</span>'}
function pauseRecording(){if(recorder?.state!=='recording')return;elapsedBeforePause+=Date.now()-startedAt;recorder.pause();clearInterval(timerHandle);$('recordState').textContent='ПАУЗА';$('recordHint').textContent='Запись приостановлена';$('pauseBtn').textContent='▶ Продолжить';document.querySelector('.record-card').classList.remove('recording');updateTimer()}
function resumeRecording(){if(recorder?.state!=='paused')return;startedAt=Date.now();recorder.resume();timerHandle=setInterval(updateTimer,250);$('recordState').textContent='ИДЁТ ЗАПИСЬ';$('recordHint').textContent='Идёт запись. Не закрывайте приложение.';$('pauseBtn').textContent='Ⅱ Пауза';document.querySelector('.record-card').classList.add('recording')}
function finishRecording(){if(!recorder||recorder.state==='inactive')return;if(recorder.state==='recording')elapsedBeforePause+=Date.now()-startedAt;clearInterval(timerHandle);recorder.stop();stream?.getTracks().forEach(t=>t.stop());$('recordState').textContent='СОХРАНЯЕМ…';$('recordHint').textContent='Подготавливаем аудиофайл';$('finishBtn').disabled=true;$('pauseBtn').disabled=true}
async function saveRecording(){const type=recorder?.mimeType||chunks[0]?.type||'audio/webm';const blob=new Blob(chunks,{type});const duration=elapsedBeforePause;const item={id:makeId(),type:'audio',title:'Запись '+new Intl.DateTimeFormat('ru-RU',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}).format(new Date()),createdAt:Date.now(),duration,blob,notes:''};try{await putItem(item);showToast('Запись сохранена на устройстве');}catch(e){showToast('Не удалось сохранить запись');console.error(e)}finally{recorder=null;stream=null;chunks=[];clearInterval(timerHandle);$('timer').innerHTML='00:00<span> / запись</span>';$('recordState').textContent='ГОТОВ К ЗАПИСИ';$('recordHint').textContent='Нажмите кнопку, чтобы начать запись';$('micStatus').textContent='ОЖИДАНИЕ';$('recordBtn').setAttribute('aria-label','Начать запись');$('pauseBtn').textContent='Ⅱ Пауза';$('pauseBtn').disabled=true;$('finishBtn').disabled=true;document.querySelector('.record-card').classList.remove('recording');$('recordBtn').classList.remove('is-recording');await refreshLists()}}
$('quickNoteBtn').onclick=()=>{$('noteTitle').value='';$('noteBody').value='';$('noteDialog').showModal()};

$('importAudioBtn').onclick=()=>$('audioFileInput').click();
$('audioFileInput').addEventListener('change',async e=>{
 const file=e.target.files&&e.target.files[0];e.target.value='';if(!file)return;
 const lower=file.name.toLowerCase();
 const known=['.m4a','.mp3','.wav','.aac','.ogg','.opus','.webm','.caf'].some(ext=>lower.endsWith(ext));
 if(!file.type.startsWith('audio/')&&!known){showToast('Выберите аудиофайл');return}
 if(file.size>250*1024*1024){showToast('Файл больше 250 МБ. Выберите запись поменьше.');return}
 try{
  const objectUrl=URL.createObjectURL(file);
  const duration=await new Promise(resolve=>{
   const audio=new Audio();audio.preload='metadata';
   const finish=value=>{URL.revokeObjectURL(objectUrl);resolve(value)};
   audio.onloadedmetadata=()=>finish(Number.isFinite(audio.duration)?Math.round(audio.duration*1000):0);
   audio.onerror=()=>finish(0);audio.src=objectUrl;
  });
  const dot=file.name.lastIndexOf('.');
  const title=dot>0?file.name.slice(0,dot):file.name;
  await putItem({id:makeId(),type:'audio',title,fileName:file.name,createdAt:Date.now(),duration,blob:file,notes:''});
  showToast('Аудиофайл добавлен в библиотеку');await refreshLists();setTab('library');
 }catch(err){console.error(err);showToast('Не удалось сохранить файл. Возможно, не хватает памяти.')}
});

$('saveNoteBtn').onclick=async()=>{const body=$('noteBody').value.trim(),title=$('noteTitle').value.trim()||'Новая заметка';if(!body){showToast('Добавьте текст заметки');return}await putItem({id:makeId(),type:'note',title,body,notes:'',createdAt:Date.now(),duration:0});$('noteDialog').close();showToast('Заметка сохранена');await refreshLists()};
function itemMarkup(item){const icon=item.type==='audio'?'♫':'✳',sub=item.type==='audio'?'Аудиозапись · '+fmtDate(item.createdAt):'Заметка · '+fmtDate(item.createdAt);return '<div class="record-item" data-id="'+item.id+'"><div class="item-icon">'+icon+'</div><div class="item-main"><div class="item-title"></div><div class="item-sub">'+sub+'</div></div><div class="item-duration">'+(item.type==='audio'?fmtTime(item.duration):'↗')+'</div></div>'}
function addItems(container,items){container.innerHTML='';if(!items.length){container.innerHTML='<div class="empty-state">Пока здесь пусто. Создайте первую запись.</div>';return}items.forEach(item=>{const wrap=document.createElement('div');wrap.innerHTML=itemMarkup(item);const node=wrap.firstElementChild;node.querySelector('.item-title').textContent=item.title;node.onclick=()=>openDetail(item.id);container.appendChild(node)})}
async function refreshLists(){const items=(await allItems()).sort((a,b)=>b.createdAt-a.createdAt);$('countBadge').textContent=items.length;addItems($('recentList'),items.slice(0,3));if(!$('libraryView').hidden)renderLibrary()}
async function renderLibrary(){const items=(await allItems()).sort((a,b)=>b.createdAt-a.createdAt),q=$('searchInput').value.trim().toLowerCase();const filtered=items.filter(i=>(activeFilter==='all'||i.type===activeFilter)&&(!q||(i.title+' '+(i.notes||'')+' '+(i.body||'')).toLowerCase().includes(q)));addItems($('libraryList'),filtered)}
$('searchInput').addEventListener('input',renderLibrary);
document.querySelectorAll('.filter-chip').forEach(b=>b.onclick=()=>{activeFilter=b.dataset.filter;document.querySelectorAll('.filter-chip').forEach(x=>x.classList.toggle('selected',x===b));renderLibrary()});
async function openDetail(id){const item=(await allItems()).find(x=>x.id===id);if(!item)return;currentItem=item;$('detailTitle').value=item.title;$('detailMeta').textContent=(item.type==='audio'?'Аудиозапись · '+fmtTime(item.duration)+' · ':'Текстовая заметка · ')+fmtDate(item.createdAt);$('detailNotes').value=item.notes||item.body||'';const player=$('audioPlayerWrap');player.innerHTML='';if(item.type==='audio'){const audio=document.createElement('audio');audio.controls=true;audio.preload='metadata';audio.src=URL.createObjectURL(item.blob);player.appendChild(audio);$('downloadBtn').hidden=false}else{$('downloadBtn').hidden=true} $('detailDialog').showModal()}
$('saveDetailBtn').onclick=async()=>{if(!currentItem)return;currentItem.title=$('detailTitle').value.trim()||'Без названия';if(currentItem.type==='audio')currentItem.notes=$('detailNotes').value;else currentItem.body=$('detailNotes').value;await putItem(currentItem);$('detailDialog').close();showToast('Изменения сохранены');await refreshLists()};
$('downloadBtn').onclick=()=>{if(!currentItem?.blob)return;const url=URL.createObjectURL(currentItem.blob),a=document.createElement('a');a.href=url;a.download=currentItem.fileName||(currentItem.title||'audio').replace(/[\\/:*?"<>|]/g,'_')+'.'+(currentItem.blob.type.includes('mp4')?'m4a':'webm');a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
$('deleteBtn').onclick=async()=>{if(!currentItem||!confirm('Удалить эту запись без возможности восстановления?'))return;await removeItem(currentItem.id);$('detailDialog').close();showToast('Запись удалена');await refreshLists()};
let deferredInstall=null;window.addEventListener('beforeinstallprompt',e=>{e.preventDefault();deferredInstall=e;$('installBtn').hidden=false});$('installBtn').onclick=async()=>{if(deferredInstall){deferredInstall.prompt();await deferredInstall.userChoice;deferredInstall=null;$('installBtn').hidden=true}else showToast('В Safari нажмите «Поделиться» → «На экран Домой»')};
if('serviceWorker'in navigator&&location.protocol.startsWith('http'))window.addEventListener('load',()=>navigator.serviceWorker.register('./sw.js').catch(console.warn));
(async()=>{try{db=await openDB();try{if(navigator.storage&&navigator.storage.persist)await navigator.storage.persist()}catch{}await refreshLists()}catch(e){showToast('Хранилище недоступно в этом браузере');console.error(e)}})();
