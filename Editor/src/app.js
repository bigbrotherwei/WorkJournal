import { createEditor, safeURL, SessionState, MAX_TEXT } from './core.js';
import { buildToolbar } from './toolbar.js';
import { documentOutline, documentMatches, textMatches, replaceMatches, searchKey } from './workflow.js';
const $ = id => document.getElementById(id);
let state, editor, mode='document', dirty=false, pending=new Map(), linkSelection, imageSelection;
let reading=false, query='', matchIndex=0;
const post = (type, extra={}) => { if(state) window.webkit?.messageHandlers.notebook.postMessage(state.message(type,extra)); };
function notice(message) { $('notice').textContent=message; $('notice').hidden=!message; }
function read() { return mode==='source' ? $('source').value : dirty ? editor.getMarkdown() : state.current(); }
function commit() {
  if(!state || state.composing)return;
  const markdown=read();
  if(new TextEncoder().encode(markdown).length>MAX_TEXT)throw new Error('笔记超过 8 MiB，当前内容尚未保存');
  if(mode==='source' && markdown!==editor.getMarkdown())editor.applyMarkdown(markdown);
  state.edit(markdown);dirty=false;post('change',{markdown:state.current()});
}
function changed() {try{commit();refreshWorkflow();}catch(e){notice(e.message);post('error',{message:e.message});}}
function capture(replace=false) { const token=crypto.randomUUID(); pending.set(token,{bookmark:editor.state.selection.getBookmark(),replace}); return token; }
function requestImage(replace=false) { if(reading || state.composing)return;const token=capture(replace);post('pickImage',{token}); }
async function imageFiles(files) {
  if(reading)return;const expected=state;
  for(const file of Array.from(files).filter(f=>/^image\/(png|jpeg|gif|webp|tiff|heic|heif)$/.test(f.type)).slice(0,20)) {
    if(file.size>16*1024*1024){notice('粘贴或拖入的单张图片不得超过 16 MiB，请使用图片按钮选择。');continue;}
    const token=capture();const data=await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(String(r.result).split(',')[1]);r.onerror=reject;r.readAsDataURL(file);});
    if(state!==expected || !pending.has(token))return;
    post('importImage',{token,data,fileName:file.name || '粘贴图片.png',mimeType:file.type});
  }
}
function mount(markdown) {
  editor?.destroy();$('document').replaceChildren();
  editor=createEditor({element:$('document'),noteID:state.noteID,markdown,editorProps:{handleDOMEvents:{compositionstart:()=>{state.composing=true;return false;},compositionend:()=>{setTimeout(()=>{state.endComposition();changed();},0);return false;},paste:(_view,event)=>{if(event.clipboardData?.files.length){event.preventDefault();imageFiles(event.clipboardData.files).catch(e=>notice(String(e)));return true;}return false;},drop:(view,event)=>{if(event.dataTransfer?.files.length){event.preventDefault();const pos=view.posAtCoords({left:event.clientX,top:event.clientY});if(pos)editor.commands.setTextSelection(pos.pos);imageFiles(event.dataTransfer.files).catch(e=>notice(String(e)));return true;}return false;},click:(_view,event)=>{const link=event.target.closest('a');if(link){event.preventDefault();if(event.metaKey)post('openURL',{url:link.getAttribute('href')});}return false;},dblclick:(_view,event)=>{if(event.target.tagName==='IMG'){showImage();return true;}return false;}}}});
  editor.on('transaction',({transaction,appendedTransactions=[]})=>{
    for(const value of pending.values())value.bookmark=value.bookmark.map(transaction.mapping);updateToolbar();
    // Transaction events also include source-only whitespace undo, for which the
    // rendered document is equal and Tiptap deliberately emits no update event.
    if(!transaction.getMeta('preventUpdate') && [transaction,...appendedTransactions].some(tr=>tr.docChanged)){
      if(mode==='source')$('source').value=editor.getMarkdown();
      dirty=true;changed();
    }
  });
  editor.setEditable(!reading,false);dirty=false;updateToolbar();refreshWorkflow();
}
async function setMode(next) {
  if(!state || next===mode)return;
  const expected=state;
  await state.flush(()=>{commit();return state.current();});
  if(state!==expected)return;
  pending.clear();closeAdvanced();mode=next;
  if(next==='source')$('source').value=state.current();
  $('source').hidden=next!=='source';$('document').hidden=next!=='document';$('toolbar').hidden=next==='source'||reading;
  $('source-mode').classList.toggle('active',next==='source');$('document-mode').classList.toggle('active',next==='document');
  $('status').textContent=reading?'阅读模式 · 本地':next==='source'?'Markdown 源码 · 本地':'文档 · 本地';refreshWorkflow();
}
$('source-mode').onclick=()=>setMode('source').catch(e=>notice(e.message));$('document-mode').onclick=()=>setMode('document').catch(e=>notice(e.message));
$('source').addEventListener('input',()=>{if(reading){$('source').value=state.current();return;}changed();});$('source').addEventListener('compositionstart',()=>{state.composing=true;});$('source').addEventListener('compositionend',()=>{setTimeout(()=>{state.endComposition();changed();},0);});
const commands = {
 bold:()=>editor.chain().focus().toggleBold().run(),italic:()=>editor.chain().focus().toggleItalic().run(),underline:()=>editor.chain().focus().toggleUnderline().run(),strike:()=>editor.chain().focus().toggleStrike().run(),code:()=>editor.chain().focus().toggleCode().run(),subscript:()=>editor.chain().focus().toggleSubscript().run(),superscript:()=>editor.chain().focus().toggleSuperscript().run(),bulletList:()=>editor.chain().focus().toggleBulletList().run(),orderedList:()=>editor.chain().focus().toggleOrderedList().run(),taskList:()=>editor.chain().focus().toggleTaskList().run(),blockquote:()=>editor.chain().focus().toggleBlockquote().run(),codeBlock:()=>editor.chain().focus().toggleCodeBlock().run(),horizontalRule:()=>editor.chain().focus().setHorizontalRule().run(),undo:()=>editor.commands.undo(),redo:()=>editor.commands.redo(),image:()=>requestImage(),link:()=>showLink(),clear:()=>editor.chain().focus().unsetAllMarks().clearNodes().run(),imageEdit:()=>showImage()
};
const {heading,language,closeAdvanced}=buildToolbar({container:$('toolbar'),getEditor:()=>reading||state?.composing?null:editor,commands});
function outline() {
  if(mode==='document')return documentOutline(editor.state.doc);
  const result=[];let offset=0,fence=null;
  for(const line of $('source').value.split('\n')){
    const marker=/^ {0,3}(`{3,}|~{3,})/.exec(line);
    if(marker){if(!fence)fence=marker[1];else if(marker[1][0]===fence[0]&&marker[1].length>=fence.length)fence=null;}
    else if(!fence){const h=/^ {0,3}(#{1,6})[ \t]+(.+)$/.exec(line);if(h)result.push({position:offset,level:h[1].length,text:h[2].replace(/ +#+ *$/,'')});}
    offset+=line.length+1;
  }return result;
}
function jumpToHeading(position) {
  if(state.composing)return;
  if(mode==='source'){$('source').focus();$('source').setSelectionRange(position,position);}
  else {const node=editor.state.doc.nodeAt(position);if(node?.type.name!=='heading')return;editor.commands.setTextSelection(position+1);editor.view.nodeDOM(position)?.scrollIntoView?.({block:'center'});}
}
function matches(){return mode==='source'?textMatches($('source').value,query):documentMatches(editor.state.doc,query);}
function refreshWorkflow(){
  if(!editor)return;
  const items=outline(),container=$('outline-list');container.replaceChildren();
  if(!items.length){const empty=document.createElement('span');empty.textContent='添加标题后将在这里显示目录';container.append(empty);}
  for(const item of items){const button=document.createElement('button');button.textContent=item.text;button.style.paddingLeft=`${8+(item.level-1)*12}px`;button.onclick=()=>jumpToHeading(item.position);container.append(button);}
  const count=matches().length;matchIndex=Math.max(0,Math.min(matchIndex,count-1));$('find-count').textContent=count?`${matchIndex+1} / ${count}`:'无匹配';
  if(mode==='document' && searchKey.getState(editor.state)!==query)editor.view.dispatch(editor.state.tr.setMeta(searchKey,query));
}
function find(text,direction=0){
  query=typeof text==='string'?text:'';$('find-text').value=query;$('find-panel').hidden=false;
  const found=matches();matchIndex=found.length?(direction?(matchIndex+direction+found.length)%found.length:0):0;refreshWorkflow();
  if(!state.composing && found.length){const range=found[matchIndex];if(mode==='source'){$('source').setSelectionRange(range.from,range.to);}else{editor.commands.setTextSelection(range);const point=editor.view.domAtPos(range.from).node; (point.nodeType===3?point.parentElement:point)?.scrollIntoView?.({block:'center'});}}
  return {count:found.length,index:matchIndex};
}
function replace(text,replacement,all=false){
  if(reading || state.composing)return 0;
  if(typeof replacement!=='string')return 0;
  query=text;const found=matches();const ranges=all?found:(found[matchIndex]?[found[matchIndex]]:[]);
  const projected=new TextEncoder().encode(read()).length+ranges.length*new TextEncoder().encode(replacement).length;
  if(projected>MAX_TEXT){notice('替换后内容超过 8 MiB，未进行修改');return 0;}
  let count=0;
  if(mode==='document')count=replaceMatches(editor,text,replacement,all,matchIndex);
  else {let value=$('source').value;for(const range of ranges.slice().reverse())value=value.slice(0,range.from)+replacement+value.slice(range.to);if(ranges.length)setSource(value);count=ranges.length;}
  find(text);return count;
}
function setSource(value){$('source').value=value;changed();}
function sourceHistory(redo=false){
  if(reading || state.composing)return;
  editor.commands[redo?'redo':'undo']();
}
async function setReading(value){
  const expected=state;await state.flush(()=>{commit();return state.current();});if(state!==expected)return;
  reading=!!value;editor.setEditable(!reading,false);$('source').readOnly=reading;$('toolbar').hidden=reading||mode==='source';
  $('reading-mode').setAttribute('aria-pressed',String(reading));$('reading-mode').textContent=reading?'继续编辑':'阅读';
  $('replace-text').disabled=reading;$('replace-one').disabled=reading;$('replace-all').disabled=reading;
  $('status').textContent=reading?'阅读模式 · 本地':mode==='source'?'Markdown 源码 · 本地':'文档 · 本地';post('readingChanged',{reading});
}
function setFontSize(value){const size=Math.max(12,Math.min(24,Number(value)||14));document.documentElement.style.setProperty('--editor-font-size',`${size}px`);$('font-size').value=String(size);post('fontChanged',{fontSize:size});}
$('outline-toggle').onclick=()=>{$('outline-list').hidden=!$('outline-list').hidden;$('outline-toggle').setAttribute('aria-expanded',String(!$('outline-list').hidden));};
$('find-toggle').onclick=()=>{$('find-panel').hidden=!$('find-panel').hidden;if(!$('find-panel').hidden)$('find-text').focus();};
$('find-close').onclick=()=>{query='';refreshWorkflow();$('find-panel').hidden=true;};
$('find-text').oninput=()=>find($('find-text').value);
$('find-next').onclick=()=>find(query,1);$('find-previous').onclick=()=>find(query,-1);
$('replace-one').onclick=()=>replace(query,$('replace-text').value);$('replace-all').onclick=()=>replace(query,$('replace-text').value,true);
$('reading-mode').onclick=()=>setReading(!reading).catch(e=>notice(e.message));$('font-size').onchange=()=>setFontSize($('font-size').value);
function updateToolbar(){if(!editor)return;document.querySelectorAll('[data-command]').forEach(b=>b.setAttribute('aria-pressed',String(editor.isActive(b.dataset.command))));heading.value=String(editor.getAttributes('heading').level || 0);language.value=editor.getAttributes('codeBlock').language || '';language.disabled=!editor.isActive('codeBlock');}
function showLink(){if(reading || state.composing)return;linkSelection=editor.state.selection.getBookmark();$('link-text').value=editor.state.doc.textBetween(editor.state.selection.from,editor.state.selection.to);$('link-url').value=editor.getAttributes('link').href || '';$('link-dialog').showModal();}
$('link-dialog').addEventListener('close',()=>{if(!editor || reading || state.composing)return;const action=$('link-dialog').returnValue;const url=$('link-url').value.trim();if(!['save','remove','open'].includes(action))return;if(action==='open'){if(safeURL(url,state.noteID))post('openURL',{url});return;}editor.view.dispatch(editor.state.tr.setSelection(linkSelection.resolve(editor.state.doc)));if(action==='remove'){editor.chain().focus().extendMarkRange('link').unsetLink().run();return;}if(!safeURL(url,state.noteID)){notice('请输入有效的 http、https、mailto 或本笔记附件地址。');return;}const text=$('link-text').value;const chain=editor.chain().focus().extendMarkRange('link');if(text)chain.insertContent({type:'text',text,marks:[{type:'link',attrs:{href:url}}]}).run();else chain.setLink({href:url}).run();});
function showImage(){if(reading || state.composing)return;if(!editor.isActive('image')){notice('请先点击正文中的图片，再打开图片操作。');return;}imageSelection=editor.state.selection.getBookmark();$('image-alt').value=editor.getAttributes('image').alt || '';$('image-dialog').showModal();}
$('image-dialog').addEventListener('close',()=>{if(reading || state.composing)return;const action=$('image-dialog').returnValue;if(!['save','remove','replace','view'].includes(action))return;editor.view.dispatch(editor.state.tr.setSelection(imageSelection.resolve(editor.state.doc)));if(action==='save')editor.chain().focus().updateAttributes('image',{alt:$('image-alt').value}).run();if(action==='remove')editor.chain().focus().deleteSelection().run();if(action==='replace')requestImage(true);if(action==='view')post('openURL',{url:editor.getAttributes('image').src});});
document.addEventListener('keydown',event=>{if((event.metaKey || event.ctrlKey)&&event.key.toLowerCase()==='f'){event.preventDefault();$('find-panel').hidden=false;$('find-text').focus();}if(event.target===$('source')&&mode==='source'&&(event.metaKey || event.ctrlKey)&&event.key.toLowerCase()==='z'){event.preventDefault();sourceHistory(event.shiftKey);}if((event.metaKey || event.ctrlKey)&&event.key.toLowerCase()==='s'){event.preventDefault();post('saveRequested');}if((event.metaKey || event.ctrlKey)&&event.key.toLowerCase()==='k'&&mode==='document'){event.preventDefault();showLink();}});
window.notebook = {
  initialize(payload) { if(typeof payload.markdown!=='string'||new TextEncoder().encode(payload.markdown).length>MAX_TEXT)throw new Error('笔记内容超过编辑器限制');state?.endComposition();state=new SessionState(payload.noteID,payload.sessionID,payload.sequence,payload.markdown);pending.clear();closeAdvanced();mode='document';query='';$('find-text').value='';$('find-panel').hidden=true;notice('');mount(payload.markdown);$('source').hidden=true;$('document').hidden=false;$('toolbar').hidden=reading;$('source').readOnly=reading;$('source-mode').classList.remove('active');$('document-mode').classList.add('active');post('ready'); },
  async flush(payload) {if(!state || payload.noteID!==state.noteID || payload.sessionID!==state.sessionID)throw new Error('编辑会话已变化');if(state.composing)document.activeElement?.blur();await state.flush(()=>{commit();return state.current();});if(payload.sessionID!==state.sessionID)throw new Error('编辑会话已变化');if(state.composing)throw new Error('输入法尚未完成');commit();return state.message('flush',{markdown:state.current()});},
  imageResult(payload) {if(!state || reading || payload.noteID!==state.noteID || payload.sessionID!==state.sessionID)return;const point=pending.get(payload.token);pending.delete(payload.token);if(!point)return;if(payload.error){notice(payload.error);return;}if(!safeURL(payload.reference,state.noteID,true))return;try{const selection=point.bookmark.resolve(editor.state.doc);editor.view.dispatch(editor.state.tr.setSelection(selection));if(point.replace&&editor.isActive('image'))editor.chain().focus().updateAttributes('image',{src:payload.reference}).run();else editor.chain().focus().setImage({src:payload.reference,alt:payload.alt || ''}).run();}catch{notice('图片已导入，但插入位置已被删除；请重新插入。');}},
  command(name) {if(name==='source')return setMode('source');if(name==='document')return setMode('document');if(reading || state.composing)return;if(mode==='source'){if(name==='undo'||name==='redo')sourceHistory(name==='redo');}else commands[name]?.();},
  find, outline, jumpToHeading, replace, setReading, setFontSize,
  async insertMarkdown(markdown) {
    if(reading)throw new Error('阅读模式下不能插入模板');
    const expected=state;await state.flush(()=>{commit();return state.current();});
    if(state!==expected)throw new Error('编辑会话已变化');if(reading)throw new Error('阅读模式下不能插入模板');
    if(typeof markdown!=='string'||new TextEncoder().encode(read()+'\n\n'+markdown).length>MAX_TEXT)throw new Error('笔记超过 8 MiB');
    if(!markdown.trim())return;
    if(mode==='source'){const text=$('source').value;setSource(text+(text?(text.endsWith('\n\n')?'':text.endsWith('\n')?'\n':'\n\n'):'')+markdown);}else editor.appendMarkdown(markdown);
  },
  async selectedText() {
    const expected=state;await state.flush(()=>{commit();return state.current();});if(state!==expected)throw new Error('编辑会话已变化');
    return mode==='source'?$('source').value.slice($('source').selectionStart,$('source').selectionEnd):editor.state.doc.textBetween(editor.state.selection.from,editor.state.selection.to,'\n');
  }

};
window.webkit?.messageHandlers.notebook.postMessage({type:'boot'});
