import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { JSDOM } from 'jsdom';
const dom=new JSDOM(await readFile(new URL('../src/index.html',import.meta.url),'utf8'),{url:'https://editor.invalid',pretendToBeVisual:true});
for(const key of ['window','document','navigator','Node','HTMLElement','DOMParser','MutationObserver','getComputedStyle','FileReader'])Object.defineProperty(globalThis,key,{value:dom.window[key],configurable:true});
// jsdom has no text layout; supply geometry only so real selection/undo transactions can run.
dom.window.Range.prototype.getClientRects=()=>[];
dom.window.Range.prototype.getBoundingClientRect=()=>({top:0,left:0,right:0,bottom:0,width:0,height:0});
globalThis.requestAnimationFrame=fn=>setTimeout(fn,0);globalThis.cancelAnimationFrame=clearTimeout;
const messages=[];window.webkit={messageHandlers:{notebook:{postMessage:m=>messages.push(m)}}};
await import('../src/app.js');
const noteID='11111111-1111-4111-8111-111111111111',sessionID='22222222-2222-4222-8222-222222222222';
const payload={noteID,sessionID,sequence:0,markdown:'# Exact  \n\n  * A\n\n'};
const app=window.notebook;
test('no-edit mode changes and flush preserve original source byte for byte',async()=>{app.initialize(payload);await app.command('source');await app.command('document');const result=await app.flush(payload);assert.equal(result.markdown,payload.markdown);assert.equal(result.sequence,0);assert.ok(document.querySelector('[data-command=imageEdit]'));assert.ok(document.querySelector('[data-command=link]'));assert.ok(document.querySelector('[data-command=taskList]'));});
test('source edits survive source/document/source transitions',async()=>{app.initialize(payload);await app.command('source');const source=document.getElementById('source');source.value='Before **bold** 中文\n';source.dispatchEvent(new window.Event('input'));await app.command('document');assert.match(document.getElementById('document').textContent,/Before bold 中文/);await app.command('source');assert.equal(source.value,'Before **bold** 中文\n');assert.equal((await app.flush(payload)).sequence,1);});
test('stale session flush and image callbacks cannot change another note',async()=>{app.initialize(payload);app.command('image');const request=messages.findLast(x=>x.type==='pickImage');const newer={...payload,sessionID:'33333333-3333-4333-8333-333333333333',markdown:'Another'};app.initialize(newer);app.imageResult({...request,reference:`workjournal-asset://${noteID}/44444444-4444-4444-8444-444444444444`});assert.equal((await app.flush(newer)).markdown,'Another');await assert.rejects(()=>app.flush(payload),/会话/);});
test('image callback token is single-use and inserts at its document position',async()=>{app.initialize({...payload,markdown:'Before'});app.command('image');const request=messages.findLast(x=>x.type==='pickImage');const reply={...request,reference:`workjournal-asset://${noteID}/44444444-4444-4444-8444-444444444444`,alt:'synthetic'};app.imageResult(reply);app.imageResult(reply);const result=await app.flush(payload);assert.equal((result.markdown.match(/workjournal-asset/g)||[]).length,1);assert.match(result.markdown,/Before/);});
test('actual source composition blocks native flush until completed input event',async()=>{app.initialize(payload);await app.command('source');const source=document.getElementById('source');source.dispatchEvent(new window.CompositionEvent('compositionstart'));source.value='中文完成';source.dispatchEvent(new window.Event('input'));let completed=false;const flush=app.flush(payload).then(r=>{completed=true;return r;});await new Promise(r=>setTimeout(r,20));assert.equal(completed,false);source.dispatchEvent(new window.CompositionEvent('compositionend'));const result=await flush;assert.equal(result.markdown,'中文完成');});
test('oversize unsaved input fails flush instead of reporting the old document as saved',async()=>{app.initialize(payload);await app.command('source');const source=document.getElementById('source');source.value='x'.repeat(8*1024*1024+1);source.dispatchEvent(new window.Event('input'));await assert.rejects(()=>app.flush(payload),/8 MiB/);assert.equal(source.value.length,8*1024*1024+1);});
test('mounted task items use inline checkbox layout with content alongside',async()=>{
  const style=document.createElement('style');style.textContent=await readFile(new URL('../src/editor.css',import.meta.url),'utf8');document.head.append(style);
  app.initialize({...payload,markdown:'- [x] checked\n- [ ] unchecked'});
  const items=document.querySelectorAll('.tiptap ul[data-type=taskList] > li');assert.equal(items.length,2);
  for(const item of items){assert.equal(window.getComputedStyle(item).display,'flex');assert.equal(window.getComputedStyle(item.querySelector(':scope > div')).flexGrow,'1');assert.ok(item.querySelector(':scope > label input[type=checkbox]'));}
  assert.equal(items[0].querySelector('input').checked,true);assert.equal(items[1].querySelector('input').checked,false);
});
test('Command-click internal note link sends an explicit native request',async()=>{
  const url='workjournal-note://33333333-3333-4333-8333-333333333333';
  app.initialize({...payload,markdown:`[Related](${url})`});
  const link=document.querySelector('.tiptap a');assert.ok(link);
  link.dispatchEvent(new window.MouseEvent('click',{bubbles:true,cancelable:true,metaKey:true}));
  assert.equal(messages.at(-1).type,'openURL');assert.equal(messages.at(-1).url,url);
});
test('compact toolbar groups SVG controls and reveals every advanced format',async()=>{
  app.initialize({...payload,markdown:'Toolbar text'});
  const main=document.getElementById('toolbar-main'),advanced=document.getElementById('toolbar-advanced'),more=document.getElementById('more-format');
  assert.ok(main);assert.ok(advanced);assert.ok(more);assert.equal(advanced.hidden,true);assert.equal(more.getAttribute('aria-expanded'),'false');
  assert.ok(main.querySelectorAll('[role=group]').length>=4);assert.ok(main.querySelectorAll('[data-command]').length<=12);
  for(const button of main.querySelectorAll('[data-command]')){assert.ok(button.querySelector('svg'));assert.ok(button.getAttribute('aria-label'));}
  more.click();assert.equal(advanced.hidden,false);assert.equal(more.getAttribute('aria-expanded'),'true');
  for(const name of ['code','subscript','superscript','blockquote','codeBlock','horizontalRule','clear','imageEdit'])assert.ok(advanced.querySelector(`[data-command=${name}]`));
  for(const label of ['文字颜色','高亮颜色','段落对齐','代码语言'])assert.ok(advanced.querySelector(`[aria-label="${label}"]`));
  assert.equal((await app.flush(payload)).markdown,'Toolbar text');
  more.dispatchEvent(new window.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert.equal(advanced.hidden,true);
});
test('source switch closes advanced formatting after composition finishes without changing text',async()=>{
  app.initialize({...payload,markdown:'Keep selection'});document.getElementById('more-format').click();
  const editable=document.querySelector('.tiptap');editable.dispatchEvent(new window.CompositionEvent('compositionstart',{bubbles:true}));
  let done=false;const change=app.command('source').then(()=>{done=true;});await new Promise(r=>setTimeout(r,20));assert.equal(done,false);
  editable.dispatchEvent(new window.CompositionEvent('compositionend',{bubbles:true}));await change;
  assert.equal(document.getElementById('toolbar-advanced').hidden,true);assert.equal(document.getElementById('toolbar').hidden,true);assert.equal((await app.flush(payload)).markdown,'Keep selection');
  await app.command('document');assert.equal(document.getElementById('toolbar').hidden,false);assert.equal(document.getElementById('toolbar-advanced').hidden,true);
});
test('format disclosure preserves selected text and advanced commands keep undo available',async()=>{
  app.initialize({...payload,markdown:'Plain'});
  const paragraph=document.querySelector('.tiptap p'),range=document.createRange();range.selectNodeContents(paragraph);
  const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
  const more=document.getElementById('more-format');assert.equal(more.dispatchEvent(new window.MouseEvent('mousedown',{bubbles:true,cancelable:true})),false);assert.equal(selection.toString(),'Plain');more.click();
  document.querySelector('#toolbar-advanced [data-command=blockquote]').click();assert.match((await app.flush(payload)).markdown,/^> Plain/);
  document.querySelector('#toolbar-main [data-command=undo]').click();assert.equal((await app.flush(payload)).markdown,'Plain');
});
test('reading and font changes preserve exact source and lock both surfaces',async()=>{
  app.initialize(payload);assert.equal(typeof app.setReading,'function');await app.setReading(true);
  assert.equal(document.querySelector('.tiptap').getAttribute('contenteditable'),'false');
  await app.command('bold');await app.command('source');assert.equal(document.getElementById('source').readOnly,true);
  app.setFontSize(20);assert.equal(document.documentElement.style.getPropertyValue('--editor-font-size'),'20px');
  await assert.rejects(()=>app.insertMarkdown('blocked'),/阅读/);assert.equal((await app.flush(payload)).markdown,payload.markdown);
  await app.setReading(false);
});
test('find highlights body and outline jump and replace preserve undo without full reload',async()=>{
  app.initialize({...payload,markdown:'# 第一章\n\n**中文** 中文'});assert.equal(typeof app.find,'function');
  assert.equal(app.find('中文').count,2);assert.equal(document.querySelectorAll('.search-match').length,2);
  assert.equal(app.outline()[0].text,'第一章');app.jumpToHeading(app.outline()[0].position);
  assert.equal(app.replace('中文','完成',true),2);assert.match((await app.flush(payload)).markdown,/\*\*完成\*\* 完成/);
  app.command('undo');assert.match((await app.flush(payload)).markdown,/\*\*中文\*\* 中文/);
});
test('template insertion waits for IME and appends preserving source and one undo',async()=>{
  app.initialize({...payload,markdown:'Existing'});await app.command('source');const source=document.getElementById('source');
  source.dispatchEvent(new window.CompositionEvent('compositionstart'));source.value='Existing 中文';source.dispatchEvent(new window.Event('input'));
  let done=false;const insertion=app.insertMarkdown('# Template').then(()=>done=true);await new Promise(r=>setTimeout(r,20));assert.equal(done,false);
  source.dispatchEvent(new window.CompositionEvent('compositionend'));await insertion;assert.equal((await app.flush(payload)).markdown,'Existing 中文\n\n# Template');
  app.command('undo');assert.equal((await app.flush(payload)).markdown,'Existing 中文');
});
test('selection extraction returns only selected text, and stale insertion cannot enter new note',async()=>{
  app.initialize({...payload,markdown:'Before selection'});await app.command('source');const source=document.getElementById('source');source.setSelectionRange(7,16);
  assert.equal(await app.selectedText(),'selection');
  source.dispatchEvent(new window.CompositionEvent('compositionstart'));const insertion=app.insertMarkdown('stale');
  app.initialize({...payload,sessionID:'33333333-3333-4333-8333-333333333333',markdown:'Next'});
  await assert.rejects(()=>insertion,/会话/);assert.equal((await app.flush({...payload,sessionID:'33333333-3333-4333-8333-333333333333'})).markdown,'Next');
});
test('format controls cannot change composing text and unchanged source roundtrip retains undo',async()=>{
  app.initialize({...payload,markdown:'Keep'});const editable=document.querySelector('.tiptap');
  editable.dispatchEvent(new window.CompositionEvent('compositionstart',{bubbles:true}));
  document.querySelector('[data-command=blockquote]').click();
  editable.dispatchEvent(new window.CompositionEvent('compositionend',{bubbles:true}));
  await new Promise(r=>setTimeout(r,10));assert.equal((await app.flush(payload)).markdown,'Keep');
  app.command('blockquote');await app.command('source');await app.command('document');app.command('undo');
  assert.equal((await app.flush(payload)).markdown,'Keep');
});
test('case-insensitive find selects the actual matched text and source replacement keeps surrounding content',async()=>{
  app.initialize({...payload,markdown:'Before HELLO after Hello tail'});
  assert.equal(app.find('hello').count,2);assert.equal(await app.selectedText(),'HELLO');
  app.find('hello',1);assert.equal(await app.selectedText(),'Hello');
  await app.command('source');assert.equal(app.find('hello').count,2);assert.equal(await app.selectedText(),'HELLO');
  app.find('hello',1);assert.equal(await app.selectedText(),'Hello');
  assert.equal(app.replace('hello','Done'),1);assert.equal((await app.flush(payload)).markdown,'Before HELLO after Done tail');
  app.command('undo');assert.equal((await app.flush(payload)).markdown,'Before HELLO after Hello tail');
});
test('source edits remain undoable and redoable after switching either direction',async()=>{
  app.initialize({...payload,markdown:'Before'});await app.command('source');const source=document.getElementById('source');
  source.value='After';source.dispatchEvent(new window.Event('input'));await app.command('document');
  app.command('undo');assert.equal((await app.flush(payload)).markdown,'Before');
  await app.command('source');app.command('redo');assert.equal((await app.flush(payload)).markdown,'After');
  await app.command('document');await app.command('source');app.command('undo');assert.equal((await app.flush(payload)).markdown,'Before');
});
test('cross-mode history preserves exact source, rich marks and assets in chronological order',async()=>{
  const original='# Exact  \n\nBefore **bold** ![image](workjournal-asset://'+noteID+'/44444444-4444-4444-8444-444444444444)\n';
  app.initialize({...payload,markdown:original});await app.command('source');const source=document.getElementById('source');
  const changed=original.replace('Before','After');source.value=changed;source.dispatchEvent(new window.Event('input'));await app.command('document');
  app.replace('After','Latest');await app.command('source');app.command('undo');assert.equal((await app.flush(payload)).markdown,changed);
  app.command('undo');assert.equal((await app.flush(payload)).markdown,original);
  await app.command('document');app.command('redo');assert.equal((await app.flush(payload)).markdown,changed);
  app.command('redo');const result=(await app.flush(payload)).markdown;assert.match(result,/Latest \*\*bold\*\*/);assert.match(result,/workjournal-asset:/);
});
test('source-only whitespace edits keep undo across repeated mode changes',async()=>{
  app.initialize({...payload,markdown:'Before\n'});await app.command('source');const source=document.getElementById('source');
  source.value='Before\n\n';source.dispatchEvent(new window.Event('input'));await app.command('document');await app.command('source');
  app.command('undo');assert.equal((await app.flush(payload)).markdown,'Before\n');
  app.command('redo');assert.equal((await app.flush(payload)).markdown,'Before\n\n');
});
test('empty and whitespace-only source edits undo exactly from the document surface',async()=>{
  for(const original of ['', ' ', '\n\n', '\t\n']){
    app.initialize({...payload,markdown:original});await app.command('source');const source=document.getElementById('source');
    source.value=original+'\n';source.dispatchEvent(new window.Event('input'));await app.command('document');
    app.command('undo');assert.equal((await app.flush(payload)).markdown,original);
    await app.command('source');app.command('redo');assert.equal(source.value,original+'\n');
    assert.equal((await app.flush(payload)).markdown,original+'\n');
  }
});
test('source IME commits one reversible event across a pending mode change',async()=>{
  app.initialize({...payload,markdown:'Before\n'});await app.command('source');const source=document.getElementById('source');
  source.value='Before draft\n';source.dispatchEvent(new window.Event('input'));
  source.dispatchEvent(new window.CompositionEvent('compositionstart'));
  for(const value of ['Before draft 中','Before draft 中文\n']){source.value=value;source.dispatchEvent(new window.Event('input'));}
  app.command('undo');assert.equal(source.value,'Before draft 中文\n');
  let switched=false;const switching=app.command('document').then(()=>{switched=true;});
  await new Promise(resolve=>setTimeout(resolve,10));assert.equal(switched,false);
  source.dispatchEvent(new window.CompositionEvent('compositionend'));await switching;
  assert.equal((await app.flush(payload)).markdown,'Before draft 中文\n');
  app.command('undo');assert.equal((await app.flush(payload)).markdown,'Before draft\n');
  await app.command('source');app.command('undo');assert.equal(source.value,'Before\n');
  app.command('redo');app.command('redo');assert.equal((await app.flush(payload)).markdown,'Before draft 中文\n');
});
test('a divergent edit clears shared redo and opening another note clears shared undo',async()=>{
  app.initialize({...payload,markdown:'Before'});await app.command('source');const source=document.getElementById('source');
  source.value='After';source.dispatchEvent(new window.Event('input'));await app.command('document');
  app.replace('After','Latest');app.command('undo');await app.command('source');app.command('undo');
  assert.equal(source.value,'Before');source.value='Branch';source.dispatchEvent(new window.Event('input'));
  await app.command('document');app.command('redo');assert.equal((await app.flush(payload)).markdown,'Branch');
  app.command('undo');assert.equal((await app.flush(payload)).markdown,'Before');
  const newer={...payload,sessionID:'33333333-3333-4333-8333-333333333333',markdown:'Next note'};
  app.initialize(newer);app.command('undo');await app.command('source');app.command('redo');
  assert.equal((await app.flush(newer)).markdown,'Next note');
});
test('image insertion and rich styles survive the shared source history in both directions',async()=>{
  const original='<p><u>Before</u> <span style="color: red">rich</span></p>\n';
  const reference=`workjournal-asset://${noteID}/44444444-4444-4444-8444-444444444444`;
  app.initialize({...payload,markdown:original});await app.command('source');const source=document.getElementById('source');
  const changed=original.replace('Before','After');source.value=changed;source.dispatchEvent(new window.Event('input'));await app.command('document');
  app.command('image');const request=messages.findLast(message=>message.type==='pickImage');app.imageResult({...request,reference,alt:'synthetic'});
  const withImage=(await app.flush(payload)).markdown;assert.ok(document.querySelector('.tiptap u'));assert.equal(document.querySelector('.tiptap img').getAttribute('src'),reference);
  await app.command('source');app.replace('After','Latest');await app.command('document');app.command('undo');
  assert.equal((await app.flush(payload)).markdown,withImage);app.command('undo');assert.equal((await app.flush(payload)).markdown,changed);
  await app.command('source');app.command('undo');assert.equal(source.value,original);
  app.command('redo');await app.command('document');app.command('redo');app.command('redo');
  assert.equal(document.querySelector('.tiptap u').textContent,'Latest');assert.equal(document.querySelector('.tiptap img').getAttribute('src'),reference);
  assert.equal(document.querySelector('.tiptap span[style]').style.color,'red');
});
