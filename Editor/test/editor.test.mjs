import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://editor.invalid' });
for (const key of ['window','document','navigator','Node','HTMLElement','DOMParser','MutationObserver','getComputedStyle']) Object.defineProperty(globalThis,key,{value:dom.window[key],configurable:true});
globalThis.requestAnimationFrame = fn => setTimeout(fn,0); globalThis.cancelAnimationFrame = clearTimeout;
const { createEditor, safeURL, SessionState } = await import('../src/core.js');
const note = '11111111-1111-4111-8111-111111111111';
const asset = `workjournal-asset://${note}/22222222-2222-4222-8222-222222222222`;
function roundtrip(md) { const a=createEditor({markdown:md,noteID:note}); const out=a.getMarkdown(); const b=createEditor({markdown:out,noteID:note}); const result={out,a:a.getJSON(),b:b.getJSON()}; a.destroy();b.destroy(); return result; }
test('GFM and inline images keep document semantics after actual serialization',()=>{
const x=roundtrip(`# Heading\n\nBefore ![alt](${asset}) after\n\n- [x] done\n- [ ] pending\n\n| A | B |\n| --- | --- |\n| one | two |\n\n\`\`\`javascript\nconst answer = 42;\n\`\`\`\n`);assert.deepEqual(x.b,x.a); assert.match(x.out,/javascript/);assert.match(x.out,/Before/);assert.match(x.out,/after/);assert.match(x.out,/workjournal-asset/);
});
test('controlled rich styles and merged cells survive HTML fallback',()=>{
const x=roundtrip('<p style="text-align: center"><span style="color: #ab1234">red &amp; &lt;safe&gt;</span> <u>under</u> <mark style="background-color: #f0cc22">yellow</mark> <sub>2</sub><sup>3</sup></p>\n\n<table><tbody><tr><th colspan="2"><p>wide &amp; &lt;x&gt;</p></th></tr><tr><td><p>a</p></td><td><p>b</p></td></tr></tbody></table>'); assert.deepEqual(x.b,x.a);assert.match(x.out,/colspan="2"/);assert.match(x.out,/text-align/);assert.match(x.out,/&lt;safe&gt;/);
});
test('untrusted HTML cannot create active nodes or fetch remote images',()=>{
const ed=createEditor({noteID:note,markdown:'<p onclick="alert(1)">safe<script>alert(2)</script><img src="https://evil.invalid/a.png"><a href="javascript:alert(3)">bad</a><iframe src="file:///etc/passwd"></iframe></p>'}); const html=ed.getHTML(); assert.doesNotMatch(html,/<script|onclick|href="javascript:|src="https:|<iframe|src="file:/);ed.destroy();
});
test('URL policy rejects unsafe schemes and cross-note assets',()=>{assert.equal(safeURL('javascript:alert(1)',note),null);assert.equal(safeURL('data:image/svg+xml,x',note),null);assert.equal(safeURL(asset,note),asset);assert.equal(safeURL(asset,'other'),null);assert.equal(safeURL('https://example.com',note),'https://example.com');assert.equal(safeURL('file:///tmp/test',note),null);});
test('session retains exact original until an edit and rejects stale messages',()=>{const s=new SessionState(note,'session',7,'# title\n\n');assert.equal(s.current(),'# title\n\n'); assert.equal(s.accepts({noteID:note,sessionID:'old',sequence:8}),false);assert.equal(s.accepts({noteID:note,sessionID:'session',sequence:Infinity}),false);s.edit('new');assert.equal(s.current(),'new');assert.equal(s.sequence,8);});
test('composition flush waits and returns final composed text',async()=>{const s=new SessionState(note,'session',0,'a');s.composing=true;let done=false;const flush=s.flush(()=>s.current()).then(v=>{done=true;return v;});await new Promise(r=>setTimeout(r,20));assert.equal(done,false);s.edit('中文');s.endComposition();assert.equal(await flush,'中文');});
test('unsafe paste strips resource and CSS fetches while preserving rich values',async()=>{const {sanitizeHTML}=await import('../src/core.js');const html=sanitizeHTML('<p style="text-align:right;background-image:url(https://evil.invalid)"><span style="color:red">R</span><img src="file:///secret"><img src="'+asset+'"><a href="javascript:bad()">bad</a></p>',note);assert.doesNotMatch(html,/background-image|file:|javascript:/);assert.match(html,/text-align:right/);assert.match(html,/workjournal-asset/);});
test('unrecognized syntax remains visible on a real edit',()=>{const md='Text\n\n<proprietary value="a">unknown content</proprietary>\n\n$$x^2$$\n\n[^ref]: footnote';const e=createEditor({markdown:md,noteID:note});e.commands.setTextSelection(1);e.commands.insertContent('edit');const out=e.getMarkdown();assert.match(out,/unknown content/);assert.match(out,/x\^2/);assert.match(out,/footnote/);e.destroy();});
test('image labels containing markdown delimiters survive',()=>{const e=createEditor({markdown:'hello',noteID:note});e.commands.setImage({src:asset,alt:'a] [b " & <x>',title:'a " quote'});const first=e.getJSON();const out=e.getMarkdown();const e2=createEditor({markdown:out,noteID:note});assert.deepEqual(e2.getJSON(),first);e.destroy();e2.destroy();});
test('rich checklist and nested list preserve checked state and styled children',()=>{const x=roundtrip('- [x] <u>under</u> and <span style="color: red">red</span>\n- [ ] plain');assert.deepEqual(x.b,x.a);});
test('headerless and multi-paragraph HTML table cells retain structure',()=>{const x=roundtrip('<table><tr><td><p>first</p><p>second</p></td><td><p>other</p></td></tr></table>');assert.deepEqual(x.b,x.a);});
test('unrelated heading edit preserves visible HTML comments and custom elements verbatim',()=>{
  const comment='<!-- Important note -->',custom='<custom-block secret="data"></custom-block>';
  const element=document.createElement('div');document.body.append(element);
  const e=createEditor({element,noteID:note,markdown:`# Title\n\n${comment}\n\n${custom}\n\nTail`});
  e.commands.setTextSelection(1);e.commands.insertContent('Edited ');
  const out=e.getMarkdown();assert.ok(out.includes(comment));assert.ok(out.includes(custom));
  assert.ok(e.view.dom.textContent.includes(comment));assert.ok(e.view.dom.textContent.includes(custom));
  const b=createEditor({noteID:note,markdown:out});assert.deepEqual(b.getJSON(),e.getJSON());e.destroy();b.destroy();element.remove();
});
test('code fences containing shorter backtick runs preserve code and following paragraphs',()=>{
  for(const code of ['const x = `hi`;\n```\nconsole.log(x);','`````\nend','<tag> & text\n```']){
    const md='# Title\n\n``````javascript\n'+code+'\n``````\n\nTail';
    const e=createEditor({noteID:note,markdown:md});e.commands.setTextSelection(1);e.commands.insertContent('Edited ');
    const out=e.getMarkdown(),b=createEditor({noteID:note,markdown:out});assert.deepEqual(b.getJSON(),e.getJSON());assert.equal(b.getJSON().content.at(-1).content[0].text,'Tail');e.destroy();b.destroy();
  }
});
test('escaped link titles preserve quote and backslash semantics',()=>{
  for(const title of ['a \\" quote','a \\\\ slash']){
    const x=roundtrip('[web](https://example.com "'+title+'")');assert.deepEqual(x.b,x.a);
  }
});
test('tables preserve body-row headers and different alignment in the same column',()=>{
  for(const html of [
    '<table><tr><th><p>Heading</p></th></tr><tr><th><p>Another heading</p></th></tr></table>',
    '<table><tr><th align="left"><p>Heading</p></th></tr><tr><td align="right"><p>Right</p></td></tr></table>'
  ]){const x=roundtrip(html);assert.deepEqual(x.b,x.a);}
});
test('strict internal-note links survive Markdown and rich HTML while images reject them',async()=>{
  const url='workjournal-note://33333333-3333-4333-8333-333333333333';
  assert.equal(safeURL(url,note),url);assert.equal(safeURL(url,note,true),null);
  for(const bad of [url+'/',url+'?x=1',url+'#x','workjournal-note://not-a-uuid','workjournal-note://user@33333333-3333-4333-8333-333333333333'])assert.equal(safeURL(bad,note),null);
  for(const markdown of [`[Related](${url})`,`<p><a href="${url}" title="quote &quot; test"><u>Related</u></a></p>`]){
    const x=roundtrip(markdown);assert.deepEqual(x.b,x.a);assert.ok(JSON.stringify(x.a).includes(url));
  }
  const {sanitizeHTML}=await import('../src/core.js');assert.ok(sanitizeHTML(`<a href="${url}">Related</a>`,note).includes(url));
});
