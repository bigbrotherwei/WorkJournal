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
