import { createEditor, safeURL, SessionState, MAX_TEXT } from './core.js';
import { buildToolbar } from './toolbar.js';
const $ = id => document.getElementById(id);
let state, editor, mode='document', dirty=false, pending=new Map(), linkSelection, imageSelection;
const post = (type, extra={}) => { if(state) window.webkit?.messageHandlers.notebook.postMessage(state.message(type,extra)); };
function notice(message) { $('notice').textContent=message; $('notice').hidden=!message; }
function read() { return mode==='source' ? $('source').value : dirty ? editor.getMarkdown() : state.current(); }
function commit() { if(!state || state.composing)return;state.edit(read());dirty=false;post('change',{markdown:state.current()}); }
function changed() {try{commit();}catch(e){notice(e.message);post('error',{message:e.message});}}
function capture(replace=false) { const token=crypto.randomUUID(); pending.set(token,{bookmark:editor.state.selection.getBookmark(),replace}); return token; }
function requestImage(replace=false) { const token=capture(replace);post('pickImage',{token}); }
async function imageFiles(files) {
  const expected=state;
  for(const file of Array.from(files).filter(f=>/^image\/(png|jpeg|gif|webp|tiff|heic|heif)$/.test(f.type)).slice(0,20)) {
    if(file.size>16*1024*1024){notice('粘贴或拖入的单张图片不得超过 16 MiB，请使用图片按钮选择。');continue;}
    const token=capture();const data=await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(String(r.result).split(',')[1]);r.onerror=reject;r.readAsDataURL(file);});
    if(state!==expected || !pending.has(token))return;
    post('importImage',{token,data,fileName:file.name || '粘贴图片.png',mimeType:file.type});
  }
}
function mount(markdown) {
  editor?.destroy();$('document').replaceChildren();
  editor=createEditor({element:$('document'),noteID:state.noteID,markdown,onUpdate:()=>{dirty=true;changed();},editorProps:{handleDOMEvents:{compositionstart:()=>{state.composing=true;return false;},compositionend:()=>{setTimeout(()=>{state.endComposition();changed();},0);return false;},paste:(_view,event)=>{if(event.clipboardData?.files.length){event.preventDefault();imageFiles(event.clipboardData.files).catch(e=>notice(String(e)));return true;}return false;},drop:(view,event)=>{if(event.dataTransfer?.files.length){event.preventDefault();const pos=view.posAtCoords({left:event.clientX,top:event.clientY});if(pos)editor.commands.setTextSelection(pos.pos);imageFiles(event.dataTransfer.files).catch(e=>notice(String(e)));return true;}return false;},click:(_view,event)=>{const link=event.target.closest('a');if(link){event.preventDefault();if(event.metaKey)post('openURL',{url:link.getAttribute('href')});}return false;},dblclick:(_view,event)=>{if(event.target.tagName==='IMG'){showImage();return true;}return false;}}}});
  editor.on('transaction',({transaction})=>{for(const value of pending.values())value.bookmark=value.bookmark.map(transaction.mapping);updateToolbar();});
  dirty=false;updateToolbar();
}
async function setMode(next) {
  if(!state || next===mode)return;
  const expected=state;
  await state.flush(()=>{commit();return state.current();});
  if(state!==expected)return;
  pending.clear();closeAdvanced();mode=next;
  if(next==='source')$('source').value=state.current();else mount(state.current());
  $('source').hidden=next!=='source';$('document').hidden=next!=='document';$('toolbar').hidden=next==='source';
  $('source-mode').classList.toggle('active',next==='source');$('document-mode').classList.toggle('active',next==='document');
  $('status').textContent=next==='source'?'Markdown 源码 · 本地':'文档 · 本地';
}
$('source-mode').onclick=()=>setMode('source').catch(e=>notice(e.message));$('document-mode').onclick=()=>setMode('document').catch(e=>notice(e.message));
$('source').addEventListener('input',changed);$('source').addEventListener('compositionstart',()=>{state.composing=true;});$('source').addEventListener('compositionend',()=>{setTimeout(()=>{state.endComposition();changed();},0);});
const commands = {
 bold:()=>editor.chain().focus().toggleBold().run(),italic:()=>editor.chain().focus().toggleItalic().run(),underline:()=>editor.chain().focus().toggleUnderline().run(),strike:()=>editor.chain().focus().toggleStrike().run(),code:()=>editor.chain().focus().toggleCode().run(),subscript:()=>editor.chain().focus().toggleSubscript().run(),superscript:()=>editor.chain().focus().toggleSuperscript().run(),bulletList:()=>editor.chain().focus().toggleBulletList().run(),orderedList:()=>editor.chain().focus().toggleOrderedList().run(),taskList:()=>editor.chain().focus().toggleTaskList().run(),blockquote:()=>editor.chain().focus().toggleBlockquote().run(),codeBlock:()=>editor.chain().focus().toggleCodeBlock().run(),horizontalRule:()=>editor.chain().focus().setHorizontalRule().run(),undo:()=>editor.commands.undo(),redo:()=>editor.commands.redo(),image:()=>requestImage(),link:()=>showLink(),clear:()=>editor.chain().focus().unsetAllMarks().clearNodes().run(),imageEdit:()=>showImage()
};
const {heading,language,closeAdvanced}=buildToolbar({container:$('toolbar'),getEditor:()=>editor,commands});
function updateToolbar(){if(!editor)return;document.querySelectorAll('[data-command]').forEach(b=>b.setAttribute('aria-pressed',String(editor.isActive(b.dataset.command))));heading.value=String(editor.getAttributes('heading').level || 0);language.value=editor.getAttributes('codeBlock').language || '';language.disabled=!editor.isActive('codeBlock');}
function showLink(){linkSelection=editor.state.selection.getBookmark();$('link-text').value=editor.state.doc.textBetween(editor.state.selection.from,editor.state.selection.to);$('link-url').value=editor.getAttributes('link').href || '';$('link-dialog').showModal();}
$('link-dialog').addEventListener('close',()=>{if(!editor)return;const action=$('link-dialog').returnValue;const url=$('link-url').value.trim();if(!['save','remove','open'].includes(action))return;if(action==='open'){if(safeURL(url,state.noteID))post('openURL',{url});return;}editor.view.dispatch(editor.state.tr.setSelection(linkSelection.resolve(editor.state.doc)));if(action==='remove'){editor.chain().focus().extendMarkRange('link').unsetLink().run();return;}if(!safeURL(url,state.noteID)){notice('请输入有效的 http、https、mailto 或本笔记附件地址。');return;}const text=$('link-text').value;const chain=editor.chain().focus().extendMarkRange('link');if(text)chain.insertContent({type:'text',text,marks:[{type:'link',attrs:{href:url}}]}).run();else chain.setLink({href:url}).run();});
function showImage(){if(!editor.isActive('image')){notice('请先点击正文中的图片，再打开图片操作。');return;}imageSelection=editor.state.selection.getBookmark();$('image-alt').value=editor.getAttributes('image').alt || '';$('image-dialog').showModal();}
$('image-dialog').addEventListener('close',()=>{const action=$('image-dialog').returnValue;if(!['save','remove','replace','view'].includes(action))return;editor.view.dispatch(editor.state.tr.setSelection(imageSelection.resolve(editor.state.doc)));if(action==='save')editor.chain().focus().updateAttributes('image',{alt:$('image-alt').value}).run();if(action==='remove')editor.chain().focus().deleteSelection().run();if(action==='replace')requestImage(true);if(action==='view')post('openURL',{url:editor.getAttributes('image').src});});
document.addEventListener('keydown',event=>{if((event.metaKey || event.ctrlKey)&&event.key.toLowerCase()==='s'){event.preventDefault();post('saveRequested');}if((event.metaKey || event.ctrlKey)&&event.key.toLowerCase()==='k'&&mode==='document'){event.preventDefault();showLink();}});
window.notebook = {
  initialize(payload) { if(typeof payload.markdown!=='string'||new TextEncoder().encode(payload.markdown).length>MAX_TEXT)throw new Error('笔记内容超过编辑器限制');state=new SessionState(payload.noteID,payload.sessionID,payload.sequence,payload.markdown);pending.clear();closeAdvanced();mode='document';notice('');mount(payload.markdown);$('source').hidden=true;$('document').hidden=false;$('toolbar').hidden=false;$('source-mode').classList.remove('active');$('document-mode').classList.add('active');post('ready'); },
  async flush(payload) {if(!state || payload.noteID!==state.noteID || payload.sessionID!==state.sessionID)throw new Error('编辑会话已变化');if(state.composing)document.activeElement?.blur();await state.flush(()=>{commit();return state.current();});if(payload.sessionID!==state.sessionID)throw new Error('编辑会话已变化');if(state.composing)throw new Error('输入法尚未完成');commit();return state.message('flush',{markdown:state.current()});},
  imageResult(payload) {if(!state || payload.noteID!==state.noteID || payload.sessionID!==state.sessionID)return;const point=pending.get(payload.token);pending.delete(payload.token);if(!point)return;if(payload.error){notice(payload.error);return;}if(!safeURL(payload.reference,state.noteID,true))return;try{const selection=point.bookmark.resolve(editor.state.doc);editor.view.dispatch(editor.state.tr.setSelection(selection));if(point.replace&&editor.isActive('image'))editor.chain().focus().updateAttributes('image',{src:payload.reference}).run();else editor.chain().focus().setImage({src:payload.reference,alt:payload.alt || ''}).run();}catch{notice('图片已导入，但插入位置已被删除；请重新插入。');}},
  command(name) {if(name==='source')return setMode('source');if(name==='document')return setMode('document');if(mode==='document')commands[name]?.();}
};
window.webkit?.messageHandlers.notebook.postMessage({type:'boot'});
