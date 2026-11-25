import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://editor.invalid' });
for (const key of ['window','document','navigator','Node','HTMLElement','DOMParser','MutationObserver','getComputedStyle']) Object.defineProperty(globalThis,key,{value:dom.window[key],configurable:true});
globalThis.requestAnimationFrame=fn=>setTimeout(fn,0);globalThis.cancelAnimationFrame=clearTimeout;
const {createEditor}=await import('../src/core.js');
const workflow=await import('../src/workflow.js').catch(()=>({}));
const noteID='11111111-1111-4111-8111-111111111111';
test('outline uses document headings and stable positions including Chinese and nested headings',()=>{
  const editor=createEditor({element:document.createElement("div"),noteID,markdown:'# 概览\n\nBody\n\n## 第二节\n\n```\n# not a heading\n```'});
  assert.equal(typeof workflow.documentOutline,'function');
  const headings=workflow.documentOutline(editor.state.doc);
  assert.deepEqual(headings.map(h=>[h.level,h.text]),[[1,'概览'],[2,'第二节']]);
  for(const item of headings)assert.equal(editor.state.doc.nodeAt(item.position).type.name,'heading');editor.destroy();
});
test('literal matches span adjacent formatting, never cross images or paragraphs',()=>{
  const editor=createEditor({element:document.createElement("div"),noteID,markdown:'中文**检索**中文\n\n![image](workjournal-asset://'+noteID+'/22222222-2222-4222-8222-222222222222)\n\n中文'});
  assert.equal(typeof workflow.documentMatches,'function');
  assert.equal(workflow.documentMatches(editor.state.doc,'中文检索').length,1);
  assert.equal(workflow.documentMatches(editor.state.doc,'中文').length,3);
  assert.equal(workflow.documentMatches(editor.state.doc,'中文中文').length,0);
  assert.equal(workflow.documentMatches(editor.state.doc,'').length,0);editor.destroy();
});
test('replace keeps matched bold, unrelated links/images and single-step undo',()=>{
  const editor=createEditor({element:document.createElement("div"),noteID,markdown:'Before **中文 中文** [link](https://example.com) ![image](workjournal-asset://'+noteID+'/22222222-2222-4222-8222-222222222222)'});
  const before=editor.getJSON();assert.equal(typeof workflow.replaceMatches,'function');
  assert.equal(workflow.replaceMatches(editor,'中文','完成',true),2);
  assert.match(editor.getMarkdown(),/\*\*完成 完成\*\*/);assert.match(editor.getMarkdown(),/https:\/\/example.com/);assert.match(editor.getMarkdown(),/workjournal-asset:/);
  assert.equal(editor.commands.undo(),true);assert.deepEqual(editor.getJSON(),before);editor.destroy();
});
test('reading mode blocks document transactions and template insert never replaces existing selection',()=>{
  const editor=createEditor({element:document.createElement("div"),noteID,markdown:'Keep **original**'}), before=editor.getJSON();
  editor.setEditable(false);editor.commands.selectAll();editor.commands.insertContent('blocked');
  assert.deepEqual(editor.getJSON(),before);
  editor.setEditable(true);assert.equal(typeof editor.appendMarkdown,'function');editor.appendMarkdown('## Added\n\nTemplate');
  assert.match(editor.getMarkdown(),/Keep \*\*original\*\*/);assert.match(editor.getMarkdown(),/## Added/);
  editor.commands.undo();assert.deepEqual(editor.getJSON(),before);editor.destroy();
});
test('replacement across adjacent style runs preserves both styles at corresponding characters',()=>{
  const editor=createEditor({element:document.createElement('div'),noteID,markdown:'**中**<u>文</u> tail'});
  assert.equal(workflow.replaceMatches(editor,'中文','完成',true),1);
  const text=editor.getJSON().content[0].content;
  assert.equal(text[0].text,'完');assert.equal(text[0].marks[0].type,'bold');
  assert.equal(text[1].text,'成');assert.equal(text[1].marks[0].type,'underline');
  editor.destroy();
});
test('case-insensitive literal matching keeps actual positions and styles during replacement',()=>{
  const editor=createEditor({element:document.createElement('div'),noteID,markdown:'Prefix **He**LLo hello HELLO a.b A.B tail'});
  const matches=workflow.documentMatches(editor.state.doc,'hello');assert.equal(matches.length,3);
  assert.deepEqual(matches.map(({from,to})=>editor.state.doc.textBetween(from,to)),['HeLLo','hello','HELLO']);
  assert.equal(workflow.documentMatches(editor.state.doc,'a.b').length,2);
  const before=editor.getJSON();assert.equal(workflow.replaceMatches(editor,'hello','World',true),3);
  assert.match(editor.getMarkdown(),/Prefix \*\*Wo\*\*rld World World a\.b A\.B tail/);
  editor.commands.undo();assert.deepEqual(editor.getJSON(),before);editor.destroy();
});
